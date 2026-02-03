#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Backend Manager Nenenet 3.0"

REPO_RAW_BASE="https://raw.githubusercontent.com/eze1087/backend-manager-nenenet/refs/heads/main"

ETC_DIR="/etc/backendmgr"
CFG_FILE="${ETC_DIR}/config.json"

PANEL_BIN_DST="/usr/local/bin/backendmgr"

NGX_DIR="/etc/nginx/conf.d/backendmgr"
SERVERS_DIR="${NGX_DIR}/servers"

NGX_MAIN_INCLUDE="${NGX_DIR}/backendmgr.conf"
NGX_BACKENDS_MAP="${NGX_DIR}/backends.map"
NGX_APPLY_SNIP="${NGX_DIR}/apply.conf"
NGX_LOGGING_SNIP="${NGX_DIR}/logging.conf"

NGX_BALANCER_CONF="${NGX_DIR}/balancer.conf"
NGX_BALANCED_MAP="${NGX_DIR}/balanced.map"

NGX_LIMITS_IP="${NGX_DIR}/limits_ip.map"
NGX_LIMITS_BACKEND="${NGX_DIR}/limits_backend.map"
NGX_LIMITS_URL="${NGX_DIR}/limits_url.map"

BACKUP_DIR="/etc/nginx/backendmgr-backups"

need_root() { [[ ${EUID:-999} -eq 0 ]] || { echo "ERROR: ejecutá con sudo."; exit 1; }; }

backup_file() {
  local f="$1"
  mkdir -p "$BACKUP_DIR"
  [[ -e "$f" ]] && cp -a "$f" "${BACKUP_DIR}/$(basename "$f").bak-$(date +%Y%m%d-%H%M%S)" || true
}

download_panel() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp" >/dev/null 2>&1 || true' RETURN

  local candidates=(
    "${REPO_RAW_BASE}/backendmgr"
    "${REPO_RAW_BASE}/backendmgr.txt"
    "${REPO_RAW_BASE}/backendmgr.sh"
    "https://raw.githubusercontent.com/eze1087/backend-manager-nenenet/main/backendmgr"
    "https://raw.githubusercontent.com/eze1087/backend-manager-nenenet/main/backendmgr.txt"
    "https://raw.githubusercontent.com/eze1087/backend-manager-nenenet/main/backendmgr.sh"
  )

  local ok=0 url=""
  for u in "${candidates[@]}"; do
    if curl -fsSL "$u" -o "${tmp}/backendmgr"; then
      ok=1; url="$u"; break
    fi
  done

  if [[ "$ok" -ne 1 ]]; then
    echo "ERROR: no pude descargar backendmgr desde tu repo (404)."
    echo "Subí el panel como backendmgr (o backendmgr.txt) en main."
    exit 1
  fi

  # Normaliza CRLF (Windows)
  sed -i 's/\r$//' "${tmp}/backendmgr" || true

  # Si vino como txt sin shebang
  if ! head -n1 "${tmp}/backendmgr" | grep -qE '^#!/'; then
    sed -i '1i#!/usr/bin/env bash' "${tmp}/backendmgr"
  fi

  chmod +x "${tmp}/backendmgr"
  install -m 0755 "${tmp}/backendmgr" "${PANEL_BIN_DST}"
  echo "✅ Panel descargado desde: ${url}"
}

write_base_files() {
  mkdir -p "$ETC_DIR" "$NGX_DIR" "$SERVERS_DIR" "$BACKUP_DIR" /var/lib/backendmgr /var/log/nginx
  chmod 700 "$BACKUP_DIR" || true

  if [[ ! -f "$CFG_FILE" ]]; then
    cat > "$CFG_FILE" <<'JSON'
{
  "nginx_conf": "/etc/nginx/nginx.conf",
  "header_name": "Backend",
  "primary_domain": "",
  "rate_limit_enabled": true,
  "rate_limit_rate": "10r/s",
  "rate_limit_burst": 20,
  "conn_limit": 30,
  "curl_timeout_seconds": 8,
  "traffic_window_seconds": 60,
  "stats_log_path": "/var/log/nginx/backendmgr.stats.log",
  "balance_mode": "off",
  "balance_max_slots_cap": 64
}
JSON
  fi

  [[ -f "$NGX_BACKENDS_MAP" ]] || : > "$NGX_BACKENDS_MAP"
  [[ -f "$NGX_APPLY_SNIP" ]] || : > "$NGX_APPLY_SNIP"
  [[ -f "$NGX_BALANCER_CONF" ]] || : > "$NGX_BALANCER_CONF"
  [[ -f "$NGX_BALANCED_MAP" ]] || : > "$NGX_BALANCED_MAP"
  [[ -f "$NGX_LIMITS_IP" ]] || : > "$NGX_LIMITS_IP"
  [[ -f "$NGX_LIMITS_BACKEND" ]] || : > "$NGX_LIMITS_BACKEND"
  [[ -f "$NGX_LIMITS_URL" ]] || : > "$NGX_LIMITS_URL"

  cat > "$NGX_LOGGING_SNIP" <<'EOF'
log_format backendmgr_stats '$time_local|$remote_addr|$host|$http_backend|$upstream_addr|$status|$body_bytes_sent|$request_time|$upstream_response_time|$request';
EOF

  # apply.conf base (el panel lo re-escribe)
  cat > "$NGX_APPLY_SNIP" <<'EOF'
# Backend Manager Nenenet 3.0 apply.conf
access_log /var/log/nginx/backendmgr.stats.log backendmgr_stats;
EOF

  # balancer.conf base (OFF)
  cat > "$NGX_BALANCER_CONF" <<'EOF'
# backendmgr balancer.conf (balance OFF)
map $host $backendmgr_balance { default 0; }
map $host $backendmgr_slot { default "0"; }

map $backendmgr_slot $balanced_backend_url {
    default $backend_url;
    include /etc/nginx/conf.d/backendmgr/balanced.map;
}
EOF
}

write_backendmgr_http_include() {
  cat > "$NGX_MAIN_INCLUDE" <<EOF
include ${NGX_LOGGING_SNIP};

limit_req_zone \$binary_remote_addr zone=backendmgr_req:10m rate=10r/s;
limit_conn_zone \$binary_remote_addr zone=backendmgr_conn:10m;

include ${NGX_BALANCER_CONF};

map \$remote_addr \$ip_limit_rate { default 0; include ${NGX_LIMITS_IP}; }
map \$http_backend \$backend_limit_rate { default 0; include ${NGX_LIMITS_BACKEND}; }
map \$backend_url \$url_limit_rate { default 0; include ${NGX_LIMITS_URL}; }

include ${SERVERS_DIR}/*.conf;
EOF
}

# NO tocar tu nginx.conf si ya tiene tu estructura que conecta
ensure_nginx_conf() {
  local nginx_conf="/etc/nginx/nginx.conf"
  backup_file "$nginx_conf"

  # Si ya existe y contiene el map de backend_url, no lo tocamos.
  if [[ -f "$nginx_conf" ]] && grep -q 'map\s\+\$http_backend\s\+\$backend_url' "$nginx_conf"; then
    # Solo aseguramos que incluya nuestros archivos si faltan.
    if ! grep -q '/etc/nginx/conf.d/backendmgr/backendmgr.conf' "$nginx_conf"; then
      # intentamos insertar include dentro de http { } sin romper nada
      if grep -q 'http\s*{' "$nginx_conf"; then
        awk '
          BEGIN{ins=0}
          {print}
          /http[ \t]*\{/ && ins==0{
            print "    # Backend Manager Nenenet 3.0"
            print "    include /etc/nginx/conf.d/backendmgr/backendmgr.conf;"
            ins=1
          }
        ' "$nginx_conf" > "${nginx_conf}.tmp" && mv "${nginx_conf}.tmp" "$nginx_conf"
      fi
    fi
    return 0
  fi

  # Si no existe o no está en tu formato, generamos uno compatible (sin server fijo, lo manejan los .conf)
  cat > "$nginx_conf" <<EOF
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 2048;
}

http {
    # Mapa para decidir backend basado en header HTTP personalizado
    map \$http_backend \$backend_url {
        default "http://127.0.0.1:8880";
        include ${NGX_BACKENDS_MAP};
    }

    include ${NGX_MAIN_INCLUDE};
}
EOF
}

# Wrapper definitivo: nginx abre menú (y nginx real sigue funcionando con args)
install_wrapper() {
  mkdir -p "$BACKUP_DIR"

  local SBIN="/usr/sbin/nginx"
  local SBIN_REAL="/usr/sbin/nginx.real"

  if [[ -x "$SBIN" && ! -e "$SBIN_REAL" ]]; then
    cp -a "$SBIN" "${BACKUP_DIR}/nginx.sbin.bak-$(date +%Y%m%d-%H%M%S)" || true
    mv "$SBIN" "$SBIN_REAL"
  fi

  cat > "$SBIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PANEL="/usr/local/bin/backendmgr"
REAL="/usr/sbin/nginx.real"

# Sin args => panel
if [[ $# -eq 0 ]]; then
  exec "$PANEL"
fi

# Atajos => panel
case "${1:-}" in
  menu|panel|nenenet) exec "$PANEL" ;;
esac

# Passthrough a nginx real
if [[ ! -x "$REAL" ]]; then
  REAL="/usr/sbin/nginx"
fi
exec "$REAL" "$@"
EOF

  chmod +x "$SBIN"

  # Asegurar que nginx (sin sudo) también vaya al wrapper
  if [[ -e /usr/bin/nginx ]]; then
    cp -a /usr/bin/nginx "${BACKUP_DIR}/nginx.bin.bak-$(date +%Y%m%d-%H%M%S)" || true
    rm -f /usr/bin/nginx
    ln -s /usr/sbin/nginx /usr/bin/nginx
  fi

  ln -sf /usr/sbin/nginx /usr/local/bin/nginx || true
}

install_or_update() {
  need_root
  echo "[1/9] Dependencias..."
  export DEBIAN_FRONTEND=noninteractive
  apt update -y
  apt install -y nginx curl jq gawk sed grep coreutils iproute2 net-tools nano ufw

  echo "[2/9] Archivos base..."
  write_base_files
  write_backendmgr_http_include

  echo "[3/9] Descargando panel..."
  download_panel

  echo "[4/9] nginx.conf (sin romper tu config)..."
  ensure_nginx_conf

  echo "[5/9] Wrapper nginx (nginx abre menú)..."
  install_wrapper

  echo "[6/9] Validando Nginx..."
  nginx -t

  echo "[7/9] Reload Nginx..."
  nginx -s reload >/dev/null 2>&1 || true

  echo "[8/9] Listo."
  echo "Abrir panel: nginx   (o sudo nginx)"

  read -r -p "[9/9] ¿Abrir panel ahora? (Y/n): " ans
  ans="${ans:-Y}"
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    exec /usr/local/bin/backendmgr
  fi
}

menu() {
  clear || true
  echo "==============================================================="
  echo "   🚀 ${APP_NAME}"
  echo "==============================================================="
  echo
  echo "[1] Instalar / Actualizar"
  echo "[2] Salir"
  echo
}

need_root
while true; do
  menu
  read -r -p "Opción: " op
  case "$op" in
    1) install_or_update; exit 0 ;;
    2) exit 0 ;;
    *) echo "Opción inválida"; sleep 1 ;;
  esac
done

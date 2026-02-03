#!/usr/bin/env bash
set -euo pipefail

APP_TITLE="Backend Manager Nenenet 3.0"
REPO_RAW_BASE="https://raw.githubusercontent.com/eze1087/backend-manager-nenenet/refs/heads/main"

ETC_DIR="/etc/backendmgr"
CFG_FILE="${ETC_DIR}/config.json"
REAL_NGINX_PATH_FILE="${ETC_DIR}/real_nginx_path"

PANEL_BIN_DST="/usr/local/bin/backendmgr"
WRAPPER_BIN="/usr/local/bin/nginx"

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

# ✅ Backup/restore en /etc/nginx (misma ubicación)
BACKUP_DIR="/etc/nginx/backendmgr-backups"

need_root() { [[ ${EUID:-999} -eq 0 ]] || { echo "ERROR: ejecutá como root (sudo)."; exit 1; }; }

backup_file() {
  local f="$1"
  mkdir -p "$BACKUP_DIR"
  [[ -f "$f" ]] && cp -a "$f" "${BACKUP_DIR}/$(basename "$f").bak-$(date +%Y%m%d-%H%M%S)" || true
}

download_panel() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp" >/dev/null 2>&1 || true' RETURN
  curl -fsSL "${REPO_RAW_BASE}/backendmgr" -o "${tmp}/backendmgr"
  chmod +x "${tmp}/backendmgr"
  install -m 0755 "${tmp}/backendmgr" "${PANEL_BIN_DST}"
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
  [[ -f "$NGX_BALANCED_MAP" ]] || : > "$NGX_BALANCED_MAP"
  [[ -f "$NGX_LIMITS_IP" ]] || : > "$NGX_LIMITS_IP"
  [[ -f "$NGX_LIMITS_BACKEND" ]] || : > "$NGX_LIMITS_BACKEND"
  [[ -f "$NGX_LIMITS_URL" ]] || : > "$NGX_LIMITS_URL"

  cat > "$NGX_LOGGING_SNIP" <<'EOF'
log_format backendmgr_stats '$time_local|$remote_addr|$host|$http_backend|$upstream_addr|$status|$body_bytes_sent|$request_time|$upstream_response_time|$request';
EOF

  cat > "$NGX_APPLY_SNIP" <<'EOF'
# Backend Manager Nenenet 3.0 apply.conf
# Debe ir dentro de location / del dominio madre:
# include /etc/nginx/conf.d/backendmgr/apply.conf;

access_log /var/log/nginx/backendmgr.stats.log backendmgr_stats;

# Rate limit (si está activo en config, el panel lo habilita aquí)
# Speed limit (limit_rate) lo aplica el panel via maps
EOF

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

# ✅ Este archivo existe solo para “enganchar” el panel a tu nginx.conf
#    pero tu nginx.conf queda con tu estructura exacta.
write_backendmgr_http_include() {
  cat > "$NGX_MAIN_INCLUDE" <<EOF
# ==========================================================
# Backend Manager Nenenet 3.0 - include http{}
# ==========================================================
include ${NGX_LOGGING_SNIP};

# req/conn rate-limit
limit_req_zone \$binary_remote_addr zone=backendmgr_req:10m rate=10r/s;
limit_conn_zone \$binary_remote_addr zone=backendmgr_conn:10m;

include ${NGX_BALANCER_CONF};

# speed limits maps (0=unlimited)
map \$remote_addr \$ip_limit_rate { default 0; include ${NGX_LIMITS_IP}; }
map \$http_backend \$backend_limit_rate { default 0; include ${NGX_LIMITS_BACKEND}; }
map \$backend_url \$url_limit_rate { default 0; include ${NGX_LIMITS_URL}; }

# servers del panel
include ${SERVERS_DIR}/*.conf;
EOF
}

# ✅ Genera /etc/nginx/nginx.conf con tu formato, y engancha includes correctos
apply_exact_nginx_conf_template() {
  local nginx_conf="/etc/nginx/nginx.conf"
  backup_file "$nginx_conf"

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

    # Backend Manager (rate-limit, logs, speed-limit, servers, balance)
    include ${NGX_MAIN_INCLUDE};
}
EOF
}

install_wrapper() {
  local real
  real="$(command -v nginx || true)"
  [[ -n "${real:-}" ]] || real="/usr/sbin/nginx"
  echo "$real" > "$REAL_NGINX_PATH_FILE"

  backup_file "$WRAPPER_BIN"
  cat > "$WRAPPER_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CFG_REAL="/etc/backendmgr/real_nginx_path"
REAL="/usr/sbin/nginx"
[[ -f "$CFG_REAL" ]] && REAL="$(cat "$CFG_REAL" 2>/dev/null || echo /usr/sbin/nginx)"

# sin args => abre panel
if [[ $# -eq 0 ]]; then
  exec /usr/local/bin/backendmgr
fi

# atajos
case "${1:-}" in
  menu|panel|nenenet) exec /usr/local/bin/backendmgr ;;
esac

# passthrough a nginx real
exec "$REAL" "$@"
EOF
  chmod +x "$WRAPPER_BIN"
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

  echo "[4/9] Aplicando nginx.conf EXACTO (como tu plantilla)..."
  apply_exact_nginx_conf_template

  echo "[5/9] Wrapper nginx..."
  install_wrapper

  echo "[6/9] Validando Nginx..."
  if ! timeout 12s nginx -t; then
    echo "⚠️ nginx -t falló."
    echo "   Revisá con: nginx -T | tail -n 120"
    exit 1
  fi

  echo "[7/9] Reload Nginx..."
  timeout 8s nginx -s reload >/dev/null 2>&1 || true

  echo "[8/9] Listo."
  echo "Abrir panel: sudo nginx"
  echo
  read -r -p "[9/9] ¿Abrir panel ahora? (Y/n): " ans
  ans="${ans:-Y}"
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    exec /usr/local/bin/backendmgr
  fi
}

uninstall_now() {
  need_root
  rm -f /usr/local/bin/backendmgr
  rm -f /usr/local/bin/nginx
  rm -rf /etc/backendmgr
  rm -rf /etc/nginx/conf.d/backendmgr
  echo "✅ Listo. Backups quedan en: /etc/nginx/backendmgr-backups"
}

menu() {
  clear || true
  echo "==============================================================="
  echo "   🚀 ${APP_TITLE}"
  echo "==============================================================="
  echo
  echo "[1] Instalar / Actualizar"
  echo "[2] Desinstalar"
  echo "[3] Salir"
  echo
}

need_root
while true; do
  menu
  read -r -p "Opción: " op
  case "$op" in
    1) install_or_update; exit 0 ;;
    2) uninstall_now; exit 0 ;;
    3) exit 0 ;;
    *) echo "Opción inválida"; sleep 1 ;;
  esac
done

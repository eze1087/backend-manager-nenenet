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
NGX_LOGGING_SNIP="${NGX_DIR}/logging.conf"
NGX_APPLY_SNIP="${NGX_DIR}/apply.conf"
NGX_BALANCER_CONF="${NGX_DIR}/balancer.conf"
NGX_BALANCED_MAP="${NGX_DIR}/balanced.map"
NGX_LIMITS_IP="${NGX_DIR}/limits_ip.map"
NGX_LIMITS_BACKEND="${NGX_DIR}/limits_backend.map"
NGX_LIMITS_URL="${NGX_DIR}/limits_url.map"

BACKUP_DIR="/root/backendmgr-backups"

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

  "balance_mode": "off",
  "balance_max_slots_cap": 64,

  "rate_limit_enabled": true,
  "rate_limit_rate": "10r/s",
  "rate_limit_burst": 20,
  "conn_limit": 30,

  "curl_timeout_seconds": 8,
  "traffic_window_seconds": 60,
  "stats_log_path": "/var/log/nginx/backendmgr.stats.log"
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

  [[ -f "$NGX_APPLY_SNIP" ]] || cat > "$NGX_APPLY_SNIP" <<'EOF'
# Backend Manager Nenenet 3.0 apply.conf
# Incluir dentro de location / :
# include /etc/nginx/conf.d/backendmgr/apply.conf;
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

  if [[ ! -f "$NGX_MAIN_INCLUDE" ]]; then
    cat > "$NGX_MAIN_INCLUDE" <<EOF
# ==========================================================
# Backend Manager Nenenet 3.0 - include principal (http{})
# ==========================================================
include ${NGX_LOGGING_SNIP};

# Mapa para decidir backend basado en header HTTP personalizado
map \$http_backend \$backend_url {
    default "http://127.0.0.1:8880";
    include ${NGX_BACKENDS_MAP};
}

# req/conn rate-limit
limit_req_zone \$binary_remote_addr zone=backendmgr_req:10m rate=10r/s;
limit_conn_zone \$binary_remote_addr zone=backendmgr_conn:10m;

# Balanceador
include ${NGX_BALANCER_CONF};

# Speed limits (0 = unlimited)
map \$remote_addr \$ip_limit_rate { default 0; include ${NGX_LIMITS_IP}; }
map \$http_backend \$backend_limit_rate { default 0; include ${NGX_LIMITS_BACKEND}; }
map \$backend_url \$url_limit_rate { default 0; include ${NGX_LIMITS_URL}; }

# Server blocks generados por el panel
include ${SERVERS_DIR}/*.conf;
EOF
  fi
}

migrate_minimal_nginx_conf() {
  local nginx_conf="/etc/nginx/nginx.conf"
  [[ -f "$nginx_conf" ]] || return 0

  grep -qF "include ${NGX_MAIN_INCLUDE};" "$nginx_conf" && return 0

  if ! grep -qE 'map\s+\$http_backend\s+\$backend_url' "$nginx_conf"; then
    return 0
  fi

  echo "🛠️  Detectado nginx.conf con mapa inline (modo minimal). Migrando a backendmgr..."
  backup_file "$nginx_conf"

  if [[ ! -s "$NGX_BACKENDS_MAP" ]]; then
    awk '
      BEGIN{inmap=0}
      /map[ \t]+\\$http_backend[ \t]+\\$backend_url[ \t]*\\{/ {inmap=1; next}
      inmap && /}/ {inmap=0; next}
      inmap {
        if($0 ~ /\"[^\"]+\"[ \t]+\"http:\/\//){
          gsub(/^[ \t]+/,""); gsub(/[ \t]*$/,"");
          if($0 !~ /;[ \t]*$/) $0=$0";"
          print "    "$0
        }
      }
    ' "$nginx_conf" > "${NGX_BACKENDS_MAP}.tmp" || true
    mv "${NGX_BACKENDS_MAP}.tmp" "$NGX_BACKENDS_MAP"
  fi

  local dom cto sto rto
  dom="$(grep -E '^[ \t]*server_name[ \t]+' "$nginx_conf" | head -n1 | sed -E 's/^[ \t]*server_name[ \t]+([^;]+);.*/\1/' || true)"
  cto="$(grep -E '^[ \t]*proxy_connect_timeout[ \t]+' "$nginx_conf" | head -n1 | awk '{print $2}' | tr -d ';' || true)"
  sto="$(grep -E '^[ \t]*proxy_send_timeout[ \t]+' "$nginx_conf" | head -n1 | awk '{print $2}' | tr -d ';' || true)"
  rto="$(grep -E '^[ \t]*proxy_read_timeout[ \t]+' "$nginx_conf" | head -n1 | awk '{print $2}' | tr -d ';' || true)"
  cto="${cto:-300s}"; sto="${sto:-600s}"; rto="${rto:-600s}"

  if [[ -n "${dom:-}" ]]; then
    local cur
    cur="$(jq -r '.primary_domain' "$CFG_FILE")"
    if [[ -z "${cur:-}" || "$cur" == "null" ]]; then
      jq --arg v "$dom" '.primary_domain=$v' "$CFG_FILE" > "${CFG_FILE}.tmp" && mv "${CFG_FILE}.tmp" "$CFG_FILE"
    fi

    local f="${SERVERS_DIR}/${dom}.conf"
    if [[ ! -f "$f" ]]; then
      local safe="${dom//./_}"
      cat > "$f" <<EOF
server {
    listen 80;
    listen [::]:80;

    server_name ${dom};

    access_log /var/log/nginx/${safe}.access.log;
    error_log  /var/log/nginx/${safe}.error.log;

    # Opcional: timeouts largos para backend
    proxy_connect_timeout ${cto};
    proxy_send_timeout    ${sto};
    proxy_read_timeout    ${rto};

    location / {
        proxy_pass \$backend_url;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        include /etc/nginx/conf.d/backendmgr/apply.conf;
    }
}
EOF
    fi
  fi

  cat > "$nginx_conf" <<EOF
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 2048;
}

http {
    # Backend Manager Nenenet 3.0 (incluye mapas/servers/limits)
    include ${NGX_MAIN_INCLUDE};
}
EOF
}

connect_include_into_nginx_conf() {
  local nginx_conf
  nginx_conf="$(jq -r '.nginx_conf' "$CFG_FILE")"
  [[ -f "$nginx_conf" ]] || { echo "No existe: $nginx_conf"; exit 1; }

  if ! grep -qF "include ${NGX_MAIN_INCLUDE};" "$nginx_conf"; then
    backup_file "$nginx_conf"
    awk -v inc="    include ${NGX_MAIN_INCLUDE};" '
      BEGIN{done=0}
      /^\s*http\s*\{/{
        print
        if(!done){ print inc; done=1; next }
      }
      {print}
    ' "$nginx_conf" > "${nginx_conf}.tmp" && mv "${nginx_conf}.tmp" "$nginx_conf"
  fi
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

if [[ $# -eq 0 ]]; then
  exec /usr/local/bin/backendmgr
fi

case "${1:-}" in
  menu|panel|nenenet) exec /usr/local/bin/backendmgr ;;
esac

case "${1:-}" in
  -t|-T|-V|-v|-h|-s|-q|-c|-p|-g) exec "$REAL" "$@" ;;
esac

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

  echo "[3/9] Descargando panel..."
  download_panel

  echo "[4/9] Adaptando nginx.conf (migración si es minimal)..."
  migrate_minimal_nginx_conf

  echo "[5/9] Include en nginx.conf (si aplica)..."
  connect_include_into_nginx_conf || true

  echo "[6/9] Wrapper nginx..."
  install_wrapper

  echo "[7/9] Validando Nginx..."
  if ! timeout 12s nginx -t; then
    echo "⚠️ nginx -t falló o tardó demasiado."
    echo "   Revisá con: nginx -T | tail -n 120"
    exit 1
  fi

  echo "[8/9] Reload Nginx..."
  timeout 8s nginx -s reload >/dev/null 2>&1 || true

  echo "[9/9] Listo."
  echo "Abrir panel: sudo nginx"
  echo
  read -r -p "¿Abrir panel ahora? (Y/n): " ans
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
  echo "✅ Listo. (No borro /etc/nginx ni backups en /root/backendmgr-backups)"
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

#!/usr/bin/env bash
set -euo pipefail

APP_TITLE="Backend Manager Nenenet 3.0"
PANEL_BIN_SRC="./backendmgr"
PANEL_BIN_DST="/usr/local/bin/backendmgr"

WRAPPER="/usr/local/bin/nginx"
ETC_DIR="/etc/backendmgr"
CFG="${ETC_DIR}/config.json"
REAL_NGINX_PATH_FILE="${ETC_DIR}/real_nginx_path"

NGX_DIR="/etc/nginx/conf.d/backendmgr"
NGX_MAIN_INCLUDE="${NGX_DIR}/backendmgr.conf"
NGX_BACKENDS_MAP="${NGX_DIR}/backends.map"
NGX_DOMAINS_MAP="${NGX_DIR}/domains.map"
NGX_DEFAULTS_MAP="${NGX_DIR}/defaults.map"

NGX_LOGGING_SNIP="${NGX_DIR}/logging.conf"
NGX_APPLY_SNIP="${NGX_DIR}/apply.conf"

# NUEVO:
NGX_BALANCER_CONF="${NGX_DIR}/balancer.conf"
NGX_BALANCED_MAP="${NGX_DIR}/balanced.map"
NGX_LIMITS_IP="${NGX_DIR}/limits_ip.map"
NGX_LIMITS_BACKEND="${NGX_DIR}/limits_backend.map"
NGX_LIMITS_URL="${NGX_DIR}/limits_url.map"

BACKUP_DIR="/root/backendmgr-backups"

need_root() {
  if [[ ${EUID:-999} -ne 0 ]]; then
    echo "ERROR: ejecutá como root: sudo bash install.sh"
    exit 1
  fi
}

backup_file() {
  local f="$1"
  mkdir -p "$BACKUP_DIR"
  [[ -f "$f" ]] && cp -a "$f" "${BACKUP_DIR}/$(basename "$f").bak-$(date +%Y%m%d-%H%M%S)" || true
}

menu() {
  clear
  echo "==============================================================="
  echo "   🚀 ${APP_TITLE}"
  echo "==============================================================="
  echo
  echo "Instala:"
  echo "  ✅ Panel TUI (comando: nginx)"
  echo "  ✅ Multi-dominio (server_name → backends separados)"
  echo "  ✅ Healthcheck (HTTP + latencia)"
  echo "  ✅ Balanceador: OFF / RANDOM / STICKY-IP"
  echo "  ✅ Limitador de velocidad: por IP / Backend / URL"
  echo "  ✅ Tráfico por IP o Backend + velocidad"
  echo "  ✅ Backup completo + Restore"
  echo
  echo "Comando:"
  echo "  👉 sudo nginx          (abre el panel)"
  echo "  👉 sudo nginx -t       (pasa al nginx real)"
  echo "  👉 sudo nginx -s reload"
  echo
  echo "---------------------------------------------------------------"
  echo "[1] Instalar / Actualizar"
  echo "[2] Desinstalar"
  echo "[3] Salir"
  echo "---------------------------------------------------------------"
  echo
}

install_or_update() {
  need_root

  echo "[1/8] Dependencias..."
  export DEBIAN_FRONTEND=noninteractive
  apt update -y
  apt install -y nginx curl jq gawk sed grep coreutils iproute2 net-tools nano

  echo "[2/8] Directorios..."
  mkdir -p "$ETC_DIR" "$NGX_DIR" "$BACKUP_DIR" /var/lib/backendmgr
  chmod 700 "$BACKUP_DIR"

  echo "[3/8] Instalando panel..."
  [[ -f "$PANEL_BIN_SRC" ]] || { echo "ERROR: no encuentro ${PANEL_BIN_SRC}. Ejecutá install.sh desde el repo."; exit 1; }
  install -m 0755 "$PANEL_BIN_SRC" "$PANEL_BIN_DST"

  echo "[4/8] Guardando ruta nginx real..."
  REAL_NGINX="$(command -v nginx || true)"
  [[ -n "${REAL_NGINX:-}" ]] || REAL_NGINX="/usr/sbin/nginx"
  echo "$REAL_NGINX" > "$REAL_NGINX_PATH_FILE"

  echo "[5/8] Config base..."
  if [[ ! -f "$CFG" ]]; then
    cat > "$CFG" <<'EOF'
{
  "nginx_conf": "/etc/nginx/nginx.conf",
  "header_name": "Backend",

  "balance_mode": "off", 
  "balance_max_slots_cap": 64,

  "rate_limit_enabled": true,
  "rate_limit_rate": "10r/s",
  "rate_limit_burst": 20,
  "conn_limit": 30,

  "curl_timeout_seconds": 8,

  "traffic_window_seconds": 60,
  "stats_log_path": "/var/log/nginx/backendmgr.stats.log",

  "auto_migrate_from_single_map": true
}
EOF
  fi

  NGINX_CONF="$(jq -r '.nginx_conf' "$CFG")"

  echo "[6/8] Creando Nginx snippets..."
  [[ -f "$NGX_DOMAINS_MAP" ]] || cat > "$NGX_DOMAINS_MAP" <<'EOF'
map $host $backend_domain {
    default "_default";
}
EOF

  [[ -f "$NGX_DEFAULTS_MAP" ]] || cat > "$NGX_DEFAULTS_MAP" <<'EOF'
map $backend_domain $default_backend_url {
    default "http://127.0.0.1:8880";
}
EOF

  [[ -f "$NGX_BACKENDS_MAP" ]] || : > "$NGX_BACKENDS_MAP"

  [[ -f "$NGX_LOGGING_SNIP" ]] || cat > "$NGX_LOGGING_SNIP" <<'EOF'
log_format backendmgr_stats '$time_local|$remote_addr|$host|$backend_domain|$http_backend|$upstream_addr|$status|$body_bytes_sent|$request_time|$upstream_response_time|$request';
EOF

  [[ -f "$NGX_APPLY_SNIP" ]] || cat > "$NGX_APPLY_SNIP" <<'EOF'
# Backend Manager Nenenet 3.0 apply.conf
# Incluir dentro de location / :
# include /etc/nginx/conf.d/backendmgr/apply.conf;
EOF

  # NUEVO: files de balance + limits
  [[ -f "$NGX_BALANCER_CONF" ]] || cat > "$NGX_BALANCER_CONF" <<'EOF'
# backendmgr balancer.conf
# Lo genera el panel cuando activás balanceador
map $host $backendmgr_balance { default 0; }
set $backendmgr_slot "0";
map "$backend_domain:$backendmgr_slot" $balanced_backend_url { default $default_backend_url; }
EOF

  [[ -f "$NGX_BALANCED_MAP" ]] || : > "$NGX_BALANCED_MAP"
  [[ -f "$NGX_LIMITS_IP" ]] || : > "$NGX_LIMITS_IP"
  [[ -f "$NGX_LIMITS_BACKEND" ]] || : > "$NGX_LIMITS_BACKEND"
  [[ -f "$NGX_LIMITS_URL" ]] || : > "$NGX_LIMITS_URL"

  [[ -f "$NGX_MAIN_INCLUDE" ]] || cat > "$NGX_MAIN_INCLUDE" <<EOF
# ==========================================================
# ${APP_TITLE} - Nginx include
# Multi-dominio:
#   map \$host -> \$backend_domain
#   map \$backend_domain -> \$default_backend_url
#   map "\$backend_domain:\$http_backend" -> \$backend_url
# Balance:
#   include balancer.conf -> \$balanced_backend_url + \$backendmgr_balance
# Limits:
#   maps -> \$ip_limit_rate / \$backend_limit_rate / \$url_limit_rate
# ==========================================================

include ${NGX_LOGGING_SNIP};
include ${NGX_DOMAINS_MAP};
include ${NGX_DEFAULTS_MAP};

map "\$backend_domain:\$http_backend" \$backend_url {
    default \$default_backend_url;
    include ${NGX_BACKENDS_MAP};
}

# Zonas rate-limit (panel ajusta rate en esta línea)
limit_req_zone \$binary_remote_addr zone=backendmgr_req:10m rate=10r/s;
limit_conn_zone \$binary_remote_addr zone=backendmgr_conn:10m;

# Balanceador (generado por panel)
include ${NGX_BALANCER_CONF};

# Speed limits (0 = unlimited)
map \$remote_addr \$ip_limit_rate { default 0; include ${NGX_LIMITS_IP}; }
map "\$backend_domain:\$http_backend" \$backend_limit_rate { default 0; include ${NGX_LIMITS_BACKEND}; }
map \$backend_url \$url_limit_rate { default 0; include ${NGX_LIMITS_URL}; }
EOF

  echo "[7/8] Insertando include en nginx.conf (http {})..."
  grep -qF "include ${NGX_MAIN_INCLUDE};" "$NGINX_CONF" || {
    backup_file "$NGINX_CONF"
    awk -v inc="    include ${NGX_MAIN_INCLUDE};" '
      BEGIN{done=0}
      /^\s*http\s*\{/{
        print
        if(!done){ print inc; done=1; next }
      }
      {print}
    ' "$NGINX_CONF" > "${NGINX_CONF}.tmp" && mv "${NGINX_CONF}.tmp" "$NGINX_CONF"
  }

  echo "[8/8] Wrapper 'nginx' (panel) + passthrough al nginx real..."
  backup_file "$WRAPPER"
  cat > "$WRAPPER" <<'EOF'
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
  chmod +x "$WRAPPER"

  echo
  echo "✅ Instalación/Actualización completa."
  echo
  echo "Abrir panel:   sudo nginx"
  echo "Probar config: sudo nginx -t"
  echo
  echo "📌 Para aplicar balance/limits/stats al tráfico real:"
  echo "En tu location / agregá:"
  echo "  include /etc/nginx/conf.d/backendmgr/apply.conf;"
  echo
  echo "Luego: sudo nginx -t && sudo systemctl reload nginx"
}

uninstall_now() {
  need_root
  echo "Desinstalando..."
  rm -f /usr/local/bin/backendmgr
  rm -f /usr/local/bin/nginx
  rm -rf /etc/backendmgr
  echo "✅ Listo. (No borro /etc/nginx ni backups en /root/backendmgr-backups)"
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

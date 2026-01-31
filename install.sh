#!/usr/bin/env bash
set -euo pipefail

APP_TITLE="Backend Manager Nenenet 3.0"
REPO_RAW_BASE="https://raw.githubusercontent.com/eze1087/backend-manager-nenenet/main"

ETC_DIR="/etc/backendmgr"
CFG="${ETC_DIR}/config.json"
REAL_NGINX_PATH_FILE="${ETC_DIR}/real_nginx_path"

PANEL_BIN_DST="/usr/local/bin/backendmgr"
WRAPPER="/usr/local/bin/nginx"

NGX_DIR="/etc/nginx/conf.d/backendmgr"
NGX_MAIN_INCLUDE="${NGX_DIR}/backendmgr.conf"
NGX_BACKENDS_MAP="${NGX_DIR}/backends.map"
NGX_DOMAINS_MAP="${NGX_DIR}/domains.map"
NGX_DEFAULTS_MAP="${NGX_DIR}/defaults.map"

NGX_LOGGING_SNIP="${NGX_DIR}/logging.conf"
NGX_APPLY_SNIP="${NGX_DIR}/apply.conf"

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

download_panel_to_tmp() {
  TMPDIR="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR" >/dev/null 2>&1 || true' EXIT

  echo "[DL] Descargando panel desde repo..."
  curl -fsSL "${REPO_RAW_BASE}/backendmgr" -o "${TMPDIR}/backendmgr"
  chmod +x "${TMPDIR}/backendmgr"
  PANEL_BIN_SRC="${TMPDIR}/backendmgr"
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
  echo "  ✅ Wizard inicial (1 dominio + 1 backend)"
  echo "  ✅ Healthcheck (HTTP + latencia)"
  echo "  ✅ Balanceador: OFF / RANDOM / STICKY-IP"
  echo "  ✅ Limitador de velocidad: IP / Backend / URL (0=sin límite)"
  echo "  ✅ Tráfico por IP o Backend + velocidad"
  echo "  ✅ Backup completo + Restore"
  echo
  echo "Comando:"
  echo "  👉 sudo nginx          (abre el panel)"
  echo "  👉 sudo nginx -t       (nginx real)"
  echo "  👉 sudo nginx -s reload"
  echo
  echo "---------------------------------------------------------------"
  echo "[1] Instalar / Actualizar"
  echo "[2] Desinstalar"
  echo "[3] Salir"
  echo "---------------------------------------------------------------"
  echo
}

write_base_files() {
  mkdir -p "$ETC_DIR" "$NGX_DIR" "$BACKUP_DIR" /var/lib/backendmgr
  chmod 700 "$BACKUP_DIR"

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
  "stats_log_path": "/var/log/nginx/backendmgr.stats.log"
}
EOF
  fi

  # Multilínea SIEMPRE (para que el panel pueda insertar líneas)
  cat > "$NGX_DOMAINS_MAP" <<'EOF'
map $host $backend_domain {
    default "_default";
}
EOF

  cat > "$NGX_DEFAULTS_MAP" <<'EOF'
map $backend_domain $default_backend_url {
    default "http://127.0.0.1:8880";
}
EOF

  [[ -f "$NGX_BACKENDS_MAP" ]] || : > "$NGX_BACKENDS_MAP"

  cat > "$NGX_LOGGING_SNIP" <<'EOF'
log_format backendmgr_stats '$time_local|$remote_addr|$host|$backend_domain|$http_backend|$upstream_addr|$status|$body_bytes_sent|$request_time|$upstream_response_time|$request';
EOF

  [[ -f "$NGX_APPLY_SNIP" ]] || cat > "$NGX_APPLY_SNIP" <<'EOF'
# Backend Manager Nenenet 3.0 apply.conf
# Incluir dentro de location / :
# include /etc/nginx/conf.d/backendmgr/apply.conf;
EOF

  # FIX: balancer.conf sin "set" (válido en http{})
  cat > "$NGX_BALANCER_CONF" <<'EOF'
# backendmgr balancer.conf (balance OFF)
map $host $backendmgr_balance { default 0; }
map $host $backendmgr_slot { default "0"; }

map "$backend_domain:$backendmgr_slot" $balanced_backend_url {
    default $default_backend_url;
}
EOF

  [[ -f "$NGX_BALANCED_MAP" ]] || : > "$NGX_BALANCED_MAP"
  [[ -f "$NGX_LIMITS_IP" ]] || : > "$NGX_LIMITS_IP"
  [[ -f "$NGX_LIMITS_BACKEND" ]] || : > "$NGX_LIMITS_BACKEND"
  [[ -f "$NGX_LIMITS_URL" ]] || : > "$NGX_LIMITS_URL"

  [[ -f "$NGX_MAIN_INCLUDE" ]] || cat > "$NGX_MAIN_INCLUDE" <<EOF
# ==========================================================
# Backend Manager Nenenet 3.0 - include principal (http{})
# ==========================================================
include ${NGX_LOGGING_SNIP};
include ${NGX_DOMAINS_MAP};
include ${NGX_DEFAULTS_MAP};

map "\$backend_domain:\$http_backend" \$backend_url {
    default \$default_backend_url;
    include ${NGX_BACKENDS_MAP};
}

# req/conn rate-limit
limit_req_zone \$binary_remote_addr zone=backendmgr_req:10m rate=10r/s;
limit_conn_zone \$binary_remote_addr zone=backendmgr_conn:10m;

# Balanceador
include ${NGX_BALANCER_CONF};

# Speed limits (0 = unlimited)
map \$remote_addr \$ip_limit_rate { default 0; include ${NGX_LIMITS_IP}; }
map "\$backend_domain:\$http_backend" \$backend_limit_rate { default 0; include ${NGX_LIMITS_BACKEND}; }
map \$backend_url \$url_limit_rate { default 0; include ${NGX_LIMITS_URL}; }
EOF
}

install_or_update() {
  need_root
  download_panel_to_tmp

  echo "[1/9] Dependencias..."
  export DEBIAN_FRONTEND=noninteractive
  apt update -y
  apt install -y nginx curl jq gawk sed grep coreutils iproute2 net-tools nano

  echo "[2/9] Directorios y archivos base..."
  write_base_files

  echo "[3/9] Instalando panel..."
  install -m 0755 "$PANEL_BIN_SRC" "$PANEL_BIN_DST"

  echo "[4/9] Guardando ruta del nginx real..."
  REAL_NGINX="$(command -v nginx || true)"
  [[ -n "${REAL_NGINX:-}" ]] || REAL_NGINX="/usr/sbin/nginx"
  echo "$REAL_NGINX" > "$REAL_NGINX_PATH_FILE"

  echo "[5/9] Conectando include en nginx.conf (http {})..."
  NGINX_CONF="$(jq -r '.nginx_conf' "$CFG")"
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

  echo "[6/9] Wrapper 'nginx' (panel + passthrough nginx real)..."
  backup_file "$WRAPPER"
  cat > "$WRAPPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CFG_REAL="/etc/backendmgr/real_nginx_path"
REAL="/usr/sbin/nginx"
[[ -f "$CFG_REAL" ]] && REAL="$(cat "$CFG_REAL" 2>/dev/null || echo /usr/sbin/nginx)"

# Sin args => panel
if [[ $# -eq 0 ]]; then
  exec /usr/local/bin/backendmgr
fi

# Alias explícitos
case "${1:-}" in
  menu|panel|nenenet) exec /usr/local/bin/backendmgr ;;
esac

# Flags típicos de nginx => nginx real
case "${1:-}" in
  -t|-T|-V|-v|-h|-s|-q|-c|-p|-g) exec "$REAL" "$@" ;;
esac

# Default => nginx real
exec "$REAL" "$@"
EOF
  chmod +x "$WRAPPER"

  echo "[7/9] Validando Nginx..."
  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  systemctl reload nginx

  echo "[8/9] Listo."
  echo
  echo "✅ Instalación/Actualización completa."
  echo "Abrir panel:   sudo nginx"
  echo
  echo "📌 Para aplicar balance/limits/stats AL TRÁFICO REAL:"
  echo "Agregá dentro de tu location / :"
  echo "  include /etc/nginx/conf.d/backendmgr/apply.conf;"
  echo

  echo "[9/9] Abrir panel y configurar ahora..."
  read -r -p "¿Abrir panel ahora? (Y/n): " ans
  ans="${ans:-Y}"
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    exec /usr/local/bin/backendmgr
  fi
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

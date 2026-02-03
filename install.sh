#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Backend Manager Nenenet 3.0"
REPO_PANEL_URL="https://raw.githubusercontent.com/eze1087/backend-manager-nenenet/refs/heads/main/backendmgr"

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

need_root(){ [[ ${EUID:-999} -eq 0 ]] || { echo "ERROR: ejecutá con sudo."; exit 1; }; }
backup_file(){ local f="$1"; mkdir -p "$BACKUP_DIR"; [[ -e "$f" ]] && cp -a "$f" "${BACKUP_DIR}/$(basename "$f").bak-$(date +%Y%m%d-%H%M%S)" || true; }

download_panel(){
  echo "Descargando panel: $REPO_PANEL_URL"
  curl -fsSL "$REPO_PANEL_URL" -o /tmp/backendmgr || { echo "ERROR: no pude descargar backendmgr"; exit 1; }

  # CRLF -> LF
  sed -i 's/\r$//' /tmp/backendmgr || true

  # Validación #1: shebang correcto en 1ra línea
  head -n1 /tmp/backendmgr | grep -q '^#!/usr/bin/env bash' || {
    echo "ERROR: backendmgr no tiene shebang válido en la primera línea."
    echo "Solución: subí backendmgr con saltos de línea reales (LF) y shebang en línea 1."
    exit 1
  }

  # Validación #2: no viene “aplastado” en una sola línea
  local lines
  lines="$(wc -l < /tmp/backendmgr | tr -d ' ')"
  if [[ "${lines}" -lt 20 ]]; then
    echo "ERROR: backendmgr parece estar mal subido (muy pocas líneas: ${lines})."
    echo "Eso pasa cuando el archivo quedó en una sola línea en GitHub."
    exit 1
  fi

  # Validación #3: sintaxis bash
  bash -n /tmp/backendmgr || {
    echo "ERROR: backendmgr tiene errores de sintaxis."
    exit 1
  }

  install -m 0755 /tmp/backendmgr "$PANEL_BIN_DST"
}

write_base_files(){
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

ensure_nginx_conf_no_break(){
  local nginx_conf="/etc/nginx/nginx.conf"
  backup_file "$nginx_conf"

  # Si ya tenés tu map backend_url, NO lo tocamos (para respetar tu conexión)
  if [[ -f "$nginx_conf" ]] && grep -q 'map\s\+\$http_backend\s\+\$backend_url' "$nginx_conf"; then
    # Solo insertamos include si falta
    if ! grep -q '/etc/nginx/conf.d/backendmgr/backendmgr.conf' "$nginx_conf"; then
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
    return 0
  fi

  # Si no existe o no está en formato, generamos uno compatible con tu modelo
  cat > "$nginx_conf" <<EOF
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events { worker_connections 2048; }

http {
    map \$http_backend \$backend_url {
        default "http://127.0.0.1:8880";
        include ${NGX_BACKENDS_MAP};
    }

    include ${NGX_MAIN_INCLUDE};
}
EOF
}

install_wrapper_nginx(){
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

if [[ $# -eq 0 ]]; then
  exec "$PANEL"
fi

case "${1:-}" in
  menu|panel|nenenet) exec "$PANEL" ;;
esac

if [[ ! -x "$REAL" ]]; then
  REAL="/usr/sbin/nginx"
fi
exec "$REAL" "$@"
EOF

  chmod +x "$SBIN"
  ln -sf /usr/sbin/nginx /usr/local/bin/nginx || true
}

main(){
  need_root
  echo "[1/7] Dependencias..."
  export DEBIAN_FRONTEND=noninteractive
  apt update -y
  apt install -y nginx curl jq gawk sed grep coreutils iproute2 net-tools nano ufw

  echo "[2/7] Base..."
  write_base_files

  echo "[3/7] Panel..."
  download_panel

  echo "[4/7] nginx.conf (sin romper tu config)..."
  ensure_nginx_conf_no_break

  echo "[5/7] Wrapper nginx..."
  install_wrapper_nginx

  echo "[6/7] Validando Nginx..."
  nginx -t

  echo "[7/7] Reload..."
  nginx -s reload >/dev/null 2>&1 || true

  echo
  echo "✅ Listo. Abrir panel con: nginx  (o sudo nginx)"
}

main

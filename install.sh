#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Backend Manager Nenenet 3.0"
PANEL_URL="https://raw.githubusercontent.com/eze1087/backend-manager-nenenet/refs/heads/main/backendmgr"
PANEL_DST="/usr/local/bin/backendmgr"

CFG_DIR="/etc/backendmgr"
CFG_FILE="${CFG_DIR}/config.json"

NGX_DIR="/etc/nginx/conf.d/backendmgr"
SERVERS_DIR="${NGX_DIR}/servers"
NGX_TARGETS_DIR="${NGX_DIR}/targets"
NGX_MOTHERS_DIR="${NGX_DIR}/mothers"
NGX_MOTHERS_UPSTREAMS="${NGX_DIR}/mothers_upstreams.conf"

NGX_BACKENDS_MAP="${NGX_DIR}/backends.map"
NGX_APPLY_SNIP="${NGX_DIR}/apply.conf"
NGX_MAIN_INCLUDE="${NGX_DIR}/backendmgr.conf"

NGX_BALANCER_CONF="${NGX_DIR}/balancer.conf"
NGX_BALANCED_MAP="${NGX_DIR}/balanced.map"

NGX_LIMITS_IP="${NGX_DIR}/limits_ip.map"
NGX_LIMITS_BACKEND="${NGX_DIR}/limits_backend.map"
NGX_LIMITS_URL="${NGX_DIR}/limits_url.map"

NGX_LOGGING_SNIP="${NGX_DIR}/logging.conf"
BACKUP_DIR="/etc/nginx/backendmgr-backups"

need_root(){ [[ ${EUID:-999} -eq 0 ]] || { echo "ERROR: ejecutá con sudo."; exit 1; }; }

backup_file(){
  local f="$1"
  mkdir -p "$BACKUP_DIR"
  [[ -e "$f" ]] && cp -a "$f" "${BACKUP_DIR}/$(basename "$f").bak-$(date +%Y%m%d-%H%M%S)" || true
}

write_default_cfg(){
  mkdir -p "$CFG_DIR"
  cat > "$CFG_FILE" <<'JSON'
{
  "header_name": "Backend",
  "primary_domain": "",
  "rate_limit_enabled": true,
  "rate_limit_rate": "10r/s",
  "rate_limit_burst": 20,
  "conn_limit": 30,
  "curl_timeout_seconds": 8,
  "traffic_window_seconds": 60,
  "stats_log_path": "/var/log/nginx/backendmgr.stats.log",

  "traffic_stats_enabled": true,
  "traffic_stats_since": "",
  "traffic_scan_enabled": false,
  "traffic_scan_mode": "backend",
  "traffic_scan_interval": "1min",

  "balance_mode": "off",
  "balance_max_slots_cap": 64
}
JSON
}

make_dirs(){
  mkdir -p \
    "$CFG_DIR" \
    "$NGX_DIR" "$SERVERS_DIR" "$NGX_TARGETS_DIR" "$NGX_MOTHERS_DIR" \
    "$BACKUP_DIR" /var/log/nginx /var/lib/backendmgr

  chmod 700 "$BACKUP_DIR" || true
  [[ -f "$CFG_FILE" ]] || write_default_cfg
}

ensure_cfg_keys(){
  [[ -f "$CFG_FILE" ]] || write_default_cfg
  jq . "$CFG_FILE" >/dev/null 2>&1 || write_default_cfg
}

download_panel(){
  echo "[3/9] Descargando panel..."
  curl -fsSL "$PANEL_URL" -o "$PANEL_DST"
  chmod +x "$PANEL_DST"
  bash -n "$PANEL_DST" >/dev/null
}

write_snippets_if_missing(){
  # (mantengo tu lógica; no borro nada)
  mkdir -p "$NGX_DIR"
  [[ -f "$NGX_BACKENDS_MAP" ]] || cat > "$NGX_BACKENDS_MAP" <<'EOF'
# backends.map (key -> url)
# "elnene" "http://127.0.0.1:8880";
EOF

  [[ -f "$NGX_BALANCED_MAP" ]] || cat > "$NGX_BALANCED_MAP" <<'EOF'
# balanced.map (domain -> balanced upstream)
# "example.com" "balanced_example";
EOF

  [[ -f "$NGX_LIMITS_IP" ]] || cat > "$NGX_LIMITS_IP" <<'EOF'
# limits_ip.map (ip -> rate)  e.g. "1.2.3.4" "50k";
EOF

  [[ -f "$NGX_LIMITS_BACKEND" ]] || cat > "$NGX_LIMITS_BACKEND" <<'EOF'
# limits_backend.map (backend_url -> rate)
EOF

  [[ -f "$NGX_LIMITS_URL" ]] || cat > "$NGX_LIMITS_URL" <<'EOF'
# limits_url.map (backend_url -> rate)
EOF

  [[ -f "$NGX_APPLY_SNIP" ]] || cat > "$NGX_APPLY_SNIP" <<'EOF'
# apply.conf (auto generado por panel)
EOF

  [[ -f "$NGX_LOGGING_SNIP" ]] || cat > "$NGX_LOGGING_SNIP" <<'EOF'
# logging.conf (stats)
EOF
}

ensure_backendmgr_conf(){
  [[ -f "$NGX_MAIN_INCLUDE" ]] || cat > "$NGX_MAIN_INCLUDE" <<EOF
# Backend Manager Nenenet 3.0 - include principal
include ${NGX_LOGGING_SNIP};

map \$http_backend \$backend_url {
  default "http://127.0.0.1:8880";
  include ${NGX_BACKENDS_MAP};
}

# Limits (si existen)
map \$remote_addr \$ip_limit_rate { default 0; include ${NGX_LIMITS_IP}; }
map \$http_backend \$backend_limit_rate { default 0; include ${NGX_LIMITS_BACKEND}; }
map \$backend_url \$url_limit_rate { default 0; include ${NGX_LIMITS_URL}; }

# Cascada: backend -> url -> ip
map \$backend_limit_rate \$nenenet_rate_step1 { default \$backend_limit_rate; 0 \$url_limit_rate; }
map \$nenenet_rate_step1 \$nenenet_rate { default \$nenenet_rate_step1; 0 \$ip_limit_rate; }

# Balance (si usás)
map \$backendmgr_balance \$nenenet_backend_url { 0 \$backend_url; 1 \$balanced_backend_url; }

include ${NGX_APPLY_SNIP};
EOF

  [[ -f "${NGX_DIR}/backendmgr.conf" ]] || ln -sf "$NGX_MAIN_INCLUDE" "${NGX_DIR}/backendmgr.conf" 2>/dev/null || true
}

ensure_nginx_conf_include(){
  local nginx_conf="/etc/nginx/nginx.conf"
  backup_file "$nginx_conf"

  # Si ya tiene map $http_backend $backend_url, solo aseguro include de backendmgr.conf dentro de http{}
  if grep -q 'map\s\+\$http_backend\s\+\$backend_url' "$nginx_conf"; then
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

  # Instalación limpia: nginx.conf mínimo compatible
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

    # Backend Manager Nenenet 3.0
    include /etc/nginx/conf.d/backendmgr/backendmgr.conf;
}
EOF
}

install_wrapper_nginx(){
  echo "[6/8] Wrapper nginx (nginx abre menú)..."
  local SBIN="/usr/sbin/nginx"
  local REAL="/usr/sbin/nginx.real"

  if [[ -x "$SBIN" && ! -x "$REAL" ]]; then
    cp -a "$SBIN" "${BACKUP_DIR}/nginx.sbin.bak-$(date +%Y%m%d-%H%M%S)" || true
    mv "$SBIN" "$REAL"
  fi

  cat > "$SBIN" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail

PANEL="/usr/local/bin/backendmgr"
REAL="/usr/sbin/nginx.real"
LOG="/var/log/backendmgr.wrapper.log"

log() {
  mkdir -p /var/log 2>/dev/null || true
  printf "[%s] %s\n" "$(date +%F\ %T)" "$*" >>"$LOG" 2>/dev/null || true
}

run_panel() {
  local rc=0
  log "RUN_PANEL user=$(id -u) tty=$(tty 2>/dev/null || echo none) cwd=$(pwd)"

  if [[ ! -x "$PANEL" ]]; then
    echo "ERROR: no existe o no es ejecutable: $PANEL" >/dev/tty 2>/dev/null || true
    log "ERROR panel no executable"
    return 127
  fi

  set +e
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    </dev/tty >/dev/tty 2>&1 "$PANEL"
    rc=$?
  else
    "$PANEL"
    rc=$?
  fi
  set -e

  log "PANEL_EXIT rc=$rc"

  # ✅ Solo mostrar el aviso si hubo error
  if [[ "$rc" -ne 0 && -r /dev/tty && -w /dev/tty ]]; then
    echo "" >/dev/tty
    echo "⚠️ El panel terminó (rc=$rc). Log: $LOG" >/dev/tty
    read -r -p "Enter para volver..." _ </dev/tty || true
  fi

  return "$rc"
}

if [[ $# -eq 0 ]]; then
  run_panel
  exit $?
fi

case "${1:-}" in
  menu|panel|nenenet)
    run_panel
    exit $?
  ;;
esac

if [[ ! -x "$REAL" ]]; then
  log "ERROR real nginx missing path=$REAL"
  echo "ERROR: nginx real no encontrado: $REAL" >&2
  exit 127
fi
exec "$REAL" "$@"
WRAP

  chmod +x "$SBIN"
  ln -sf /usr/sbin/nginx /usr/local/bin/nginx 2>/dev/null || true
  ln -sf /usr/sbin/nginx /usr/bin/nginx 2>/dev/null || true
  bash -n /usr/sbin/nginx
}

main(){
  need_root
  export DEBIAN_FRONTEND=noninteractive

  echo "[1/8] Dependencias..."
  apt-get update -y
  apt-get install -y nginx curl jq gawk sed grep coreutils iproute2 net-tools ufw

  echo "[2/8] Archivos base..."
  make_dirs
  ensure_cfg_keys

  download_panel

  echo "[4/8] Snippets..."
  write_snippets_if_missing
  ensure_backendmgr_conf

  echo "[5/8] nginx.conf include..."
  ensure_nginx_conf_include

  install_wrapper_nginx

  echo "[7/8] Reload..."
  if [[ -x /usr/sbin/nginx.real ]]; then
    /usr/sbin/nginx.real -t
    /usr/sbin/nginx.real -s reload >/dev/null 2>&1 || true
  else
    nginx -t
    nginx -s reload >/dev/null 2>&1 || true
  fi

  echo "[8/8] ✅ Listo. Abrir panel con: nginx  (o sudo nginx)"
}

main

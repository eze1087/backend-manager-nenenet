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

  [[ -f "$NGX_BACKENDS_MAP" ]] || : > "$NGX_BACKENDS_MAP"
  [[ -f "$NGX_APPLY_SNIP" ]] || : > "$NGX_APPLY_SNIP"
  [[ -f "$NGX_BALANCER_CONF" ]] || : > "$NGX_BALANCER_CONF"
  [[ -f "$NGX_BALANCED_MAP" ]] || : > "$NGX_BALANCED_MAP"

  [[ -f "$NGX_LIMITS_IP" ]] || : > "$NGX_LIMITS_IP"
  [[ -f "$NGX_LIMITS_BACKEND" ]] || : > "$NGX_LIMITS_BACKEND"
  [[ -f "$NGX_LIMITS_URL" ]] || : > "$NGX_LIMITS_URL"

  [[ -f "$NGX_MOTHERS_UPSTREAMS" ]] || : > "$NGX_MOTHERS_UPSTREAMS"
}

ensure_cfg_keys(){
  local tmp
  tmp="$(mktemp)"
  jq '
    .balance_max_slots_cap = (.balance_max_slots_cap // 64)
    | .traffic_stats_enabled = (.traffic_stats_enabled // true)
    | .traffic_stats_since = (.traffic_stats_since // "")
    | .traffic_scan_enabled = (.traffic_scan_enabled // false)
    | .traffic_scan_mode = (.traffic_scan_mode // "backend")
    | .traffic_scan_interval = (.traffic_scan_interval // "1min")
  ' "$CFG_FILE" > "$tmp" && mv "$tmp" "$CFG_FILE"
}

download_panel(){
  echo "[3/9] Descargando panel..."
  curl -fsSL "$PANEL_URL" -o /tmp/backendmgr || { echo "ERROR: no pude bajar backendmgr (URL 404 o sin permisos)."; exit 1; }
  sed -i 's/\r$//' /tmp/backendmgr || true
  bash -n /tmp/backendmgr || { echo "ERROR: backendmgr tiene errores de sintaxis."; exit 1; }
  install -m 0755 /tmp/backendmgr "$PANEL_DST"
}

write_snippets_if_missing(){
  # logging.conf (no pisar si existe)
  if [[ ! -s "$NGX_LOGGING_SNIP" ]]; then
    cat > "$NGX_LOGGING_SNIP" <<'EOF'
log_format backendmgr_stats '$time_local|$remote_addr|$host|$http_backend|$upstream_addr|$status|$body_bytes_sent|$request_time|$upstream_response_time|$request';
EOF
  fi

  # apply.conf (si existe, no lo piso: lo gestiona el panel)
  if [[ ! -s "$NGX_APPLY_SNIP" ]]; then
    cat > "$NGX_APPLY_SNIP" <<'EOF'
# Backend Manager Nenenet 3.0 apply.conf (placeholder)
access_log /var/log/nginx/backendmgr.stats.log backendmgr_stats;
EOF
  fi

  # balancer.conf (legacy, seguro)
  if [[ ! -s "$NGX_BALANCER_CONF" ]]; then
    cat > "$NGX_BALANCER_CONF" <<'EOF'
# backendmgr balancer.conf (legacy balance OFF)
map $host $backendmgr_balance { default 0; }
map $host $backendmgr_slot { default "0"; }

map $backendmgr_slot $balanced_backend_url {
    default $backend_url;
    include /etc/nginx/conf.d/backendmgr/balanced.map;
}
EOF
  fi

  [[ -f "$NGX_BALANCED_MAP" ]] || : > "$NGX_BALANCED_MAP"
}

write_backendmgr_conf_full(){
  cat > "$NGX_MAIN_INCLUDE" <<EOF
# ${APP_NAME} (http{})
include ${NGX_LOGGING_SNIP};

# rate-limit zones (valores reales los aplica apply.conf)
limit_req_zone \$binary_remote_addr zone=backendmgr_req:10m rate=10r/s;
limit_conn_zone \$binary_remote_addr zone=backendmgr_conn:10m;

# balancer legacy
include ${NGX_BALANCER_CONF};

# mothers upstreams (si está vacío no pasa nada)
include ${NGX_MOTHERS_UPSTREAMS};

# speed-limit maps
map \$remote_addr \$ip_limit_rate { default 0; include ${NGX_LIMITS_IP}; }
map \$http_backend \$backend_limit_rate { default 0; include ${NGX_LIMITS_BACKEND}; }
map \$backend_url \$url_limit_rate { default 0; include ${NGX_LIMITS_URL}; }

map \$backend_limit_rate \$nenenet_rate_step1 {
  default \$backend_limit_rate;
  0 \$url_limit_rate;
}
map \$nenenet_rate_step1 \$nenenet_rate {
  default \$nenenet_rate_step1;
  0 \$ip_limit_rate;
}

# ✅ IMPORTANTÍSIMO: variable usada por targets/*.conf
map \$backendmgr_balance \$nenenet_backend_url {
  0 \$backend_url;
  1 \$balanced_backend_url;
}

# servers
include ${SERVERS_DIR}/*.conf;
EOF
}

ensure_backendmgr_conf(){
  # Si no existe: lo creo completo
  if [[ ! -f "$NGX_MAIN_INCLUDE" ]]; then
    write_backendmgr_conf_full
    return 0
  fi

  # Si existe pero NO define $nenenet_backend_url: lo reparo SIN borrar lo demás
  if ! grep -q '\$nenenet_backend_url' "$NGX_MAIN_INCLUDE" 2>/dev/null; then
    backup_file "$NGX_MAIN_INCLUDE"
    # Insertar mapas antes del include servers, o al final si no lo encuentro
    awk -v mf="$NGX_MOTHERS_UPSTREAMS" -v lip="$NGX_LIMITS_IP" -v lbe="$NGX_LIMITS_BACKEND" -v lur="$NGX_LIMITS_URL" '
      BEGIN{done=0}
      {
        if(done==0 && $0 ~ /include[ \t]+.*servers\/\*\.conf;/){
          print ""
          print "# --- backendmgr auto-fix: maps requeridos ---"
          print "include " mf ";"
          print "map $remote_addr $ip_limit_rate { default 0; include " lip "; }"
          print "map $http_backend $backend_limit_rate { default 0; include " lbe "; }"
          print "map $backend_url $url_limit_rate { default 0; include " lur "; }"
          print "map $backend_limit_rate $nenenet_rate_step1 {"
          print "  default $backend_limit_rate;"
          print "  0 $url_limit_rate;"
          print "}"
          print "map $nenenet_rate_step1 $nenenet_rate {"
          print "  default $nenenet_rate_step1;"
          print "  0 $ip_limit_rate;"
          print "}"
          print "map $backendmgr_balance $nenenet_backend_url {"
          print "  0 $backend_url;"
          print "  1 $balanced_backend_url;"
          print "}"
          print ""
          done=1
        }
        print
      }
      END{
        if(done==0){
          print ""
          print "# --- backendmgr auto-fix: maps requeridos (append) ---"
          print "include " mf ";"
          print "map $remote_addr $ip_limit_rate { default 0; include " lip "; }"
          print "map $http_backend $backend_limit_rate { default 0; include " lbe "; }"
          print "map $backend_url $url_limit_rate { default 0; include " lur "; }"
          print "map $backend_limit_rate $nenenet_rate_step1 { default $backend_limit_rate; 0 $url_limit_rate; }"
          print "map $nenenet_rate_step1 $nenenet_rate { default $nenenet_rate_step1; 0 $ip_limit_rate; }"
          print "map $backendmgr_balance $nenenet_backend_url { 0 $backend_url; 1 $balanced_backend_url; }"
        }
      }
    ' "$NGX_MAIN_INCLUDE" > "${NGX_MAIN_INCLUDE}.tmp" && mv "${NGX_MAIN_INCLUDE}.tmp" "$NGX_MAIN_INCLUDE"
  fi
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

  if [[ -r /dev/tty && -w /dev/tty ]]; then
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
  REAL="/usr/sbin/nginx"
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

  echo "[7/8] Reload..."
  nginx -t
  nginx -s reload >/dev/null 2>&1 || true

  install_wrapper_nginx

  echo "[8/8] ✅ Listo. Abrir panel con: nginx  (o sudo nginx)"
}

main

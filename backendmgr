#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Backend Manager Nenenet 3.0"
APP_VER="3.7"

CFG_FILE="/etc/backendmgr/config.json"
BACKUP_DIR="/root/backendmgr-backups"

NGX_DIR="/etc/nginx/conf.d/backendmgr"
NGX_MAIN_INCLUDE="${NGX_DIR}/backendmgr.conf"
NGX_BACKENDS_MAP="${NGX_DIR}/backends.map"
NGX_APPLY_SNIP="${NGX_DIR}/apply.conf"
NGX_BALANCER_CONF="${NGX_DIR}/balancer.conf"
NGX_BALANCED_MAP="${NGX_DIR}/balanced.map"
NGX_LIMITS_IP="${NGX_DIR}/limits_ip.map"
NGX_LIMITS_BACKEND="${NGX_DIR}/limits_backend.map"
NGX_LIMITS_URL="${NGX_DIR}/limits_url.map"
SERVERS_DIR="${NGX_DIR}/servers"

NC='\033[0m'
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
CYA='\033[0;36m'
WHT='\033[1;37m'
DIM='\033[2m'

need_root() { [[ ${EUID:-999} -eq 0 ]] || { echo -e "${RED}ERROR:${NC} ejecutá: sudo nginx"; exit 1; }; }
pause() { echo; read -r -p "Enter para volver al menú..." _; }

# ✅ CLAVE: nunca cortar el menú por fallos/locks de nginx
nginx_test_reload() {
  if ! timeout 8s nginx -t; then
    echo -e "${YLW}⚠️ nginx -t falló o tardó demasiado. No hago reload.${NC}"
    return 0
  fi
  timeout 8s nginx -s reload >/dev/null 2>&1 || true
  return 0
}

read_cfg() {
  [[ -f "$CFG_FILE" ]] || { echo -e "${RED}Falta:${NC} $CFG_FILE"; return 0; }
  HEADER_NAME="$(jq -r '.header_name' "$CFG_FILE")"
  PRIMARY_DOMAIN="$(jq -r '.primary_domain' "$CFG_FILE")"
  [[ "$PRIMARY_DOMAIN" == "null" ]] && PRIMARY_DOMAIN=""

  RL_ENABLED="$(jq -r '.rate_limit_enabled' "$CFG_FILE")"
  RL_RATE="$(jq -r '.rate_limit_rate' "$CFG_FILE")"
  RL_BURST="$(jq -r '.rate_limit_burst' "$CFG_FILE")"
  CONN_LIMIT="$(jq -r '.conn_limit' "$CFG_FILE")"

  CURL_TMO="$(jq -r '.curl_timeout_seconds' "$CFG_FILE")"
  BAL_MODE="$(jq -r '.balance_mode' "$CFG_FILE")"
  BAL_CAP="$(jq -r '.balance_max_slots_cap' "$CFG_FILE")"

  STATS_LOG="$(jq -r '.stats_log_path' "$CFG_FILE")"
}

ensure_files() {
  mkdir -p "$NGX_DIR" "$SERVERS_DIR" /var/log/nginx /var/lib/backendmgr "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" || true
  for f in "$NGX_MAIN_INCLUDE" "$NGX_BACKENDS_MAP" "$NGX_APPLY_SNIP" "$NGX_BALANCER_CONF" "$NGX_BALANCED_MAP" \
           "$NGX_LIMITS_IP" "$NGX_LIMITS_BACKEND" "$NGX_LIMITS_URL"
  do
    [[ -f "$f" ]] || : > "$f"
  done
}

banner() {
  clear || true
  echo -e "${CYA}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYA}║${NC}  🚀 ${APP_NAME}  v${APP_VER}                                   ${CYA}║${NC}"
  echo -e "${CYA}║${NC}  Dominio madre principal: ${WHT}${PRIMARY_DOMAIN:-"(no configurado)"}${NC} | Header: ${WHT}${HEADER_NAME:-Backend}${NC} ${CYA}║${NC}"
  echo -e "${CYA}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo
}

quick_status() {
  echo -e "${WHT}📊 ESTADO${NC}"
  echo -e "   🌐 Dominio madre principal: ${GRN}${PRIMARY_DOMAIN:-"(no configurado)"}${NC}"
  echo -e "   ⚖️ Balance: ${GRN}${BAL_MODE}${NC}"
  echo -e "   🛡️ Rate limit: ${GRN}${RL_ENABLED}${NC} (${RL_RATE}, burst ${RL_BURST}, conn ${CONN_LIMIT})"
  echo -e "   📈 Stats log: ${DIM}${STATS_LOG}${NC}"
  echo
}

validate_domain() { [[ "$1" =~ ^[A-Za-z0-9.-]{3,253}$ ]]; }
validate_key() { [[ "$1" =~ ^[A-Za-z0-9_.:-]{2,64}$ ]]; }
validate_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

backend_lines() { grep -E '^\s*"[A-Za-z0-9_.:-]+"\s+"http://' "$NGX_BACKENDS_MAP" 2>/dev/null || true; }
server_files() { ls -1 "${SERVERS_DIR}"/*.conf 2>/dev/null || true; }

set_primary_domain() {
  echo -e "${CYA}Configurar dominio madre principal${NC}"
  echo -e "${DIM}Ejemplo: cpu2.elnene.site${NC}"
  read -r -p "Dominio madre principal: " dom
  validate_domain "$dom" || { echo -e "${RED}Dominio inválido.${NC}"; return 0; }
  jq --arg v "$dom" '.primary_domain = $v' "$CFG_FILE" > "${CFG_FILE}.tmp" && mv "${CFG_FILE}.tmp" "$CFG_FILE"
  read_cfg
  echo -e "${GRN}✅ Guardado.${NC}"
  return 0
}

add_backend() {
  echo -e "${CYA}Agregar backend (nombre + IP + puerto)${NC}"
  echo -e "${DIM}Ejemplo: backend=svpnene38 | IP=179.43.112.38 | Puerto=80${NC}"
  echo
  read -r -p "Nombre del backend (ej: svpnene38): " key
  validate_key "$key" || { echo -e "${RED}Nombre backend inválido.${NC}"; return 0; }

  read -r -p "IP (ej: 179.43.112.38): " ip
  validate_ip "$ip" || { echo -e "${RED}IP inválida.${NC}"; return 0; }

  read -r -p "Puerto (ej: 80): " port
  [[ "$port" =~ ^[0-9]{2,5}$ ]] || { echo -e "${RED}Puerto inválido.${NC}"; return 0; }

  url="http://${ip}:${port}"

  if grep -qE "^\s*\"${key}\"" "$NGX_BACKENDS_MAP"; then
    awk -v k="$key" -v url="$url" '{ re="^[ \t]*\""k"\""; if($0 ~ re){ sub(/"http:\/\/[^"]+"/, "\""url"\"") } print }' \
      "$NGX_BACKENDS_MAP" > "${NGX_BACKENDS_MAP}.tmp" && mv "${NGX_BACKENDS_MAP}.tmp" "$NGX_BACKENDS_MAP"
    echo -e "${GRN}✅ Backend actualizado:${NC} ${key} -> ${ip}:${port}"
  else
    printf "    \"%s\" \"%s\";\n" "$key" "$url" >> "$NGX_BACKENDS_MAP"
    echo -e "${GRN}✅ Backend agregado:${NC} ${key} -> ${ip}:${port}"
  fi

  rebuild_balancer_files >/dev/null 2>&1 || true
  write_apply_conf >/dev/null 2>&1 || true
  nginx_test_reload
  return 0
}

list_backends_general() {
  echo -e "${CYA}Lista general de backends${NC}\n"
  printf "%-4s %-22s %-18s %-6s\n" "#" "BACKEND" "IP" "PORT"
  echo "--------------------------------------------------------------"
  i=0
  backend_lines | while read -r line; do
    i=$((i+1))
    key="$(echo "$line" | sed -E 's/^\s*"([^"]+)".*$/\1/')"
    url="$(echo "$line" | sed -E 's/^.*"\s+"([^"]+)";\s*$/\1/')"
    ipport="${url#http://}"; ip="${ipport%%:*}"; port="${ipport##*:}"
    printf "%-4s %-22s %-18s %-6s\n" "$i" "$key" "$ip" "$port"
  done
  return 0
}

delete_backend_pick() {
  echo -e "${CYA}Eliminar backend (elegir de lista)${NC}\n"
  mapfile -t lines < <(backend_lines)
  if [[ "${#lines[@]}" -eq 0 ]]; then
    echo -e "${YLW}No hay backends cargados.${NC}"
    return 0
  fi

  idx=0
  for line in "${lines[@]}"; do
    idx=$((idx+1))
    key="$(echo "$line" | sed -E 's/^\s*"([^"]+)".*$/\1/')"
    url="$(echo "$line" | sed -E 's/^.*"\s+"([^"]+)";\s*$/\1/')"
    ipport="${url#http://}"; ip="${ipport%%:*}"; port="${ipport##*:}"
    printf "%-3s) %-22s -> %s:%s\n" "$idx" "$key" "$ip" "$port"
  done

  echo
  read -r -p "Número a eliminar: " n
  [[ "$n" =~ ^[0-9]+$ ]] || { echo -e "${RED}Número inválido.${NC}"; return 0; }
  (( n>=1 && n<=${#lines[@]} )) || { echo -e "${RED}Fuera de rango.${NC}"; return 0; }

  target="${lines[$((n-1))]}"
  grep -vF "$target" "$NGX_BACKENDS_MAP" > "${NGX_BACKENDS_MAP}.tmp" && mv "${NGX_BACKENDS_MAP}.tmp" "$NGX_BACKENDS_MAP"

  rebuild_balancer_files >/dev/null 2>&1 || true
  write_apply_conf >/dev/null 2>&1 || true
  nginx_test_reload
  echo -e "${GRN}✅ Backend eliminado.${NC}"
  return 0
}

healthcheck_all() {
  echo -e "${CYA}Healthcheck (HTTP y latencia)${NC}"
  echo -e "${DIM}Timeout curl: ${CURL_TMO}s  (000 = no responde)${NC}\n"
  printf "%-22s %-18s %-6s %-6s %-10s\n" "BACKEND" "IP" "PORT" "HTTP" "LAT(ms)"
  echo "------------------------------------------------------------------"
  backend_lines | while read -r line; do
    key="$(echo "$line" | sed -E 's/^\s*"([^"]+)".*$/\1/')"
    url="$(echo "$line" | sed -E 's/^.*"\s+"([^"]+)";\s*$/\1/')"
    ipport="${url#http://}"; ip="${ipport%%:*}"; port="${ipport##*:}"
    out="$(curl -m "$CURL_TMO" -s -o /dev/null -w "%{http_code} %{time_total}" "${url}/" || echo "000 9.999")"
    code="$(echo "$out" | awk '{print $1}')"
    t="$(echo "$out" | awk '{print $2}')"
    ms="$(awk -v x="$t" 'BEGIN{printf "%.0f", x*1000}')"
    printf "%-22s %-18s %-6s %-6s %-10s\n" "$key" "$ip" "$port" "$code" "$ms"
  done
  return 0
}

rewrite_rate_zone() {
  if grep -qE '^\s*limit_req_zone\s+\$binary_remote_addr\s+zone=backendmgr_req:10m\s+rate=' "$NGX_MAIN_INCLUDE"; then
    awk -v rate="$RL_RATE" '
      { if($0 ~ /^\s*limit_req_zone\s+\$binary_remote_addr\s+zone=backendmgr_req:10m\s+rate=/){ sub(/rate=[^;]+;/, "rate="rate";") } print }
    ' "$NGX_MAIN_INCLUDE" > "${NGX_MAIN_INCLUDE}.tmp" && mv "${NGX_MAIN_INCLUDE}.tmp" "$NGX_MAIN_INCLUDE"
  fi
}

write_apply_conf() {
  read_cfg
  rewrite_rate_zone >/dev/null 2>&1 || true
  cat > "$NGX_APPLY_SNIP" <<EOF
# ${APP_NAME} apply.conf
access_log ${STATS_LOG} backendmgr_stats;

if (\$backendmgr_balance = 1) {
    set \$backend_url \$balanced_backend_url;
}
EOF

  if [[ "$RL_ENABLED" == "true" ]]; then
    cat >> "$NGX_APPLY_SNIP" <<EOF
limit_req zone=backendmgr_req burst=${RL_BURST} nodelay;
limit_conn backendmgr_conn ${CONN_LIMIT};
EOF
  fi

  cat >> "$NGX_APPLY_SNIP" <<'EOF'
set $nenenet_rate 0;
if ($backend_limit_rate != 0) { set $nenenet_rate $backend_limit_rate; }
if ($nenenet_rate = 0) { if ($url_limit_rate != 0) { set $nenenet_rate $url_limit_rate; } }
if ($nenenet_rate = 0) { if ($ip_limit_rate != 0) { set $nenenet_rate $ip_limit_rate; } }
limit_rate $nenenet_rate;
EOF
  return 0
}

rebuild_balancer_files() {
  read_cfg
  cap="$BAL_CAP"; [[ "$cap" =~ ^[0-9]+$ ]] || cap=64
  : > "$NGX_BALANCED_MAP"
  i=0
  while read -r line; do
    url="$(echo "$line" | sed -E 's/^.*"\s+"([^"]+)";\s*$/\1/')"
    printf "    \"%s\" \"%s\";\n" "$i" "$url" >> "$NGX_BALANCED_MAP"
    i=$((i+1))
    [[ $i -ge $cap ]] && break
  done < <(backend_lines)

  if [[ $i -lt 2 || "$BAL_MODE" == "off" ]]; then
    cat > "$NGX_BALANCER_CONF" <<'EOF'
map $host $backendmgr_balance { default 0; }
map $host $backendmgr_slot { default "0"; }
map $backendmgr_slot $balanced_backend_url {
    default $backend_url;
    include /etc/nginx/conf.d/backendmgr/balanced.map;
}
EOF
    return 0
  fi

  base=$((100 / i)); rem=$((100 - base * i))
  split_key='$remote_addr'
  [[ "$BAL_MODE" == "random" ]] && split_key='$remote_addr$msec$connection'

  {
    echo "map \$host \$backendmgr_balance { default 1; }"
    echo "split_clients \"${split_key}\" \$backendmgr_slot {"
    for ((n=0;n<i;n++)); do
      pct="$base"; if (( rem > 0 )); then pct=$((pct+1)); rem=$((rem-1)); fi
      echo "    ${pct}% \"${n}\";"
    done
    echo "}"
    echo "map \$backendmgr_slot \$balanced_backend_url {"
    echo "    default \$backend_url;"
    echo "    include ${NGX_BALANCED_MAP};"
    echo "}"
  } > "$NGX_BALANCER_CONF"
  return 0
}

menu() {
  echo -e "${WHT}📌 MENÚ PRINCIPAL${NC}"
  echo "  1) 🌐 Configurar dominio madre principal"
  echo "  2) ➕ Agregar backend (nombre + IP + puerto)"
  echo "  4) 📄 Listar backends (nombre + IP + puerto)"
  echo "  6) 🗑️  Eliminar backend (elegir de lista)"
  echo "  7) ✅ Healthcheck (HTTP y latencia)"
  echo "  0) 🚪 Salir"
  echo
}

main() {
  need_root
  read_cfg
  ensure_files
  rebuild_balancer_files >/dev/null 2>&1 || true
  write_apply_conf >/dev/null 2>&1 || true

  while true; do
    banner
    quick_status
    menu
    read -r -p "Opción: " opt
    echo
    case "$opt" in
      1) set_primary_domain; pause ;;
      2) add_backend; pause ;;
      4) list_backends_general; pause ;;
      6) delete_backend_pick; pause ;;
      7) healthcheck_all; pause ;;
      0) exit 0 ;;
      *) echo -e "${YLW}Opción inválida.${NC}"; pause ;;
    esac
  done
}

main

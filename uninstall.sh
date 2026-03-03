#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Backend Manager Nenenet 3.0"

PANEL_DST="/usr/local/bin/backendmgr"

CFG_DIR="/etc/backendmgr"
NGX_DIR="/etc/nginx/conf.d/backendmgr"
BACKUP_DIR="/etc/nginx/backendmgr-backups"
STATE_DIR="/var/lib/backendmgr"

need_root(){ [[ ${EUID:-999} -eq 0 ]] || { echo "ERROR: ejecutá con sudo."; exit 1; }; }
have_systemd(){ command -v systemctl >/dev/null 2>&1; }

stop_disable_unit(){
  local u="$1"
  have_systemd || return 0
  systemctl disable --now "$u" >/dev/null 2>&1 || true
  systemctl stop "$u" >/dev/null 2>&1 || true
}

cleanup_systemd(){
  have_systemd || return 0

  # Timers/Services creados por backendmgr
  for u in \
    backendmgr-ramrefresh.timer backendmgr-ramrefresh.service \
    backendmgr-traffic-scan.timer backendmgr-traffic-scan.service \
    backendmgr-cleanup.timer backendmgr-cleanup.service \
    backendmgr-nginx-reload.timer backendmgr-nginx-reload.service \
    backendmgr-nginx-restart.timer backendmgr-nginx-restart.service
  do
    stop_disable_unit "$u"
    rm -f "/etc/systemd/system/${u}" 2>/dev/null || true
  done

  systemctl daemon-reload >/dev/null 2>&1 || true
}

restore_nginx_binary(){
  local SBIN="/usr/sbin/nginx"
  local REAL="/usr/sbin/nginx.real"

  # detener nginx antes de tocar el binario
  have_systemd && systemctl stop nginx >/dev/null 2>&1 || true

  if [[ -x "$REAL" ]]; then
    rm -f "$SBIN" 2>/dev/null || true
    mv "$REAL" "$SBIN" 2>/dev/null || true
    chmod 755 "$SBIN" 2>/dev/null || true
  fi

  # limpiar symlinks que pudo crear el instalador
  rm -f /usr/local/bin/nginx /usr/bin/nginx 2>/dev/null || true
}

main(){
  need_root

  echo "🗑️  Desinstalando: ${APP_NAME}"
  echo

  echo "[1/6] Deteniendo timers/servicios..."
  cleanup_systemd

  echo "[2/6] Restaurando nginx (quitando wrapper si existía)..."
  restore_nginx_binary

  echo "[3/6] Removiendo panel..."
  rm -f "$PANEL_DST" 2>/dev/null || true

  echo "[4/6] Removiendo configs..."
  rm -rf "$CFG_DIR" 2>/dev/null || true
  rm -rf "$NGX_DIR" 2>/dev/null || true

  echo "[5/6] Removiendo estado y logs..."
  rm -rf "$STATE_DIR" 2>/dev/null || true
  rm -f /var/log/backendmgr.panel.log /var/log/backendmgr.wrapper.log /var/log/backendmgr.wrapper.log /var/log/backendmgr.panel.log 2>/dev/null || true

  echo "[6/6] Removiendo backups (opcional pero pedido: sin rastro)..."
  rm -rf "$BACKUP_DIR" 2>/dev/null || true

  echo
  echo "✅ Listo. (Si querés, podés desinstalar dependencias manualmente: nginx/jq/etc.)"
}

main

#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-999} -ne 0 ]]; then
  echo "ERROR: sudo bash uninstall.sh"
  exit 1
fi

echo "== Backend Manager Nenenet 3.0 - Uninstall =="

rm -f /usr/local/bin/backendmgr
rm -f /usr/local/bin/nginx
rm -rf /etc/backendmgr

echo "✅ Eliminado."
echo "Nota: NO borro /etc/nginx ni /root/backendmgr-backups"

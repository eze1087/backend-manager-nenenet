# Backend Manager Nenenet 3.0

Panel TUI para administrar Nginx como “Backend Router” por header `Backend:` (CloudFront / multi-backend).

## Comando
- Abrir panel: `sudo nginx`
- Probar Nginx real: `sudo nginx -t`
- Reload Nginx real: `sudo nginx -s reload`

## Features
- Multi-dominio (server_name → backends separados)
- CRUD backends por dominio
- Default backend por dominio
- Healthcheck (HTTP + latencia)
- Rate limit + protección básica (desde panel)
- Tráfico por IP o por backend (MB/GB + velocidad)
- Backup completo + Restore

## Instalación
```bash
git clone <TU_REPO>
cd backend-manager-nenenet
sudo bash install.sh
sudo nginx

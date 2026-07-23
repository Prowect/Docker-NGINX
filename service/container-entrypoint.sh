#!/usr/bin/env sh
set -eu

prepare_runtime() {
    umask 027
    mkdir -p \
        /tmp/nginx-runtime/conf.d \
        /var/cache/nginx/client_temp \
        /var/cache/nginx/proxy_temp \
        /var/cache/nginx/fastcgi_temp \
        /var/cache/nginx/uwsgi_temp \
        /var/cache/nginx/scgi_temp \
        /var/log/modsecurity/audit/storage

    /usr/local/bin/render-runtime-config
}

if [ "${1:-serve}" != "serve" ]; then
    if [ "${1:-}" = "nginx" ]; then
        prepare_runtime
    fi
    exec "$@"
fi

prepare_runtime
nginx -t

/usr/local/bin/modsec-cleanup &
cleanup_pid=$!
nginx -g 'daemon off;' &
nginx_pid=$!
shutdown_requested=0

shutdown() {
    if [ "$shutdown_requested" -eq 1 ]; then
        return
    fi
    shutdown_requested=1
    printf '[entrypoint] graceful shutdown requested\n'
    kill -QUIT "$nginx_pid" 2>/dev/null || true
    kill -TERM "$cleanup_pid" 2>/dev/null || true
}

trap shutdown TERM INT QUIT

nginx_status=0
while kill -0 "$nginx_pid" 2>/dev/null; do
    nginx_status=0
    wait "$nginx_pid" || nginx_status=$?
done

kill -TERM "$cleanup_pid" 2>/dev/null || true
wait "$cleanup_pid" 2>/dev/null || true

printf '[entrypoint] nginx stopped with status %s\n' "$nginx_status"
exit "$nginx_status"

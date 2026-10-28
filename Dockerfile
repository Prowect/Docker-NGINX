# syntax=docker/dockerfile:1.7

ARG NGINX_IMAGE=nginx:1.31.8-alpine3.24-slim@sha256:f45171d36c76a8b2f5ef97108a3a8a2294248a6578a0a180edc2d78f7d2edc26

FROM ${NGINX_IMAGE} AS builder

ARG NGINX_VERSION=1.31.8
ARG NGINX_SHA256=0652b760b3b772d2ec17b47c2fc15d9a95e6fe35cd5b877eadc1a62d9bc75af1
ARG MODSECURITY_VERSION=v3.0.17
ARG MODSECURITY_SHA256=f283b33d5c21130fd3a15c84a93a1abe12bd1949edaf44288b12af571b671a50
ARG MODSECURITY_NGINX_VERSION=v1.0.4
ARG MODSECURITY_NGINX_SHA256=6bdc7570911be884c1e43aaf85046137f9fde0cfa0dd4a55b853c81c45a13313
ARG OWASP_CRS_VERSION=v4.30.0
ARG OWASP_CRS_SHA256=3d678a41fd5aade34760127fef5dd64fd7a77848913fc0f70dde0cf467c94427

RUN set -eux; \
    apk add --no-cache \
        build-base \
        curl \
        geoip-dev \
        libmaxminddb-dev \
        libtool \
        libxml2-dev \
        linux-headers \
        lmdb-dev \
        pcre2-dev \
        pkgconfig \
        tar \
        yajl-dev \
        zlib-dev

WORKDIR /tmp/build

RUN set -eux; \
    curl -fsSLo modsecurity.tar.gz \
        "https://github.com/owasp-modsecurity/ModSecurity/releases/download/${MODSECURITY_VERSION}/modsecurity-${MODSECURITY_VERSION}.tar.gz"; \
    echo "${MODSECURITY_SHA256}  modsecurity.tar.gz" | sha256sum -c -; \
    mkdir modsecurity; \
    tar -xzf modsecurity.tar.gz -C modsecurity --strip-components=1; \
    cd modsecurity; \
    ./configure --disable-dependency-tracking --disable-static --with-lmdb; \
    make -j"$(getconf _NPROCESSORS_ONLN)"; \
    make install; \
    cp modsecurity.conf-recommended /tmp/modsecurity.conf; \
    cp unicode.mapping /tmp/unicode.mapping

RUN set -eux; \
    curl -fsSLo modsecurity-nginx.tar.gz \
        "https://github.com/owasp-modsecurity/ModSecurity-nginx/releases/download/${MODSECURITY_NGINX_VERSION}/ModSecurity-nginx-${MODSECURITY_NGINX_VERSION}.tar.gz"; \
    echo "${MODSECURITY_NGINX_SHA256}  modsecurity-nginx.tar.gz" | sha256sum -c -; \
    mkdir modsecurity-nginx; \
    tar -xzf modsecurity-nginx.tar.gz -C modsecurity-nginx --strip-components=1; \
    curl -fsSLo nginx.tar.gz "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"; \
    echo "${NGINX_SHA256}  nginx.tar.gz" | sha256sum -c -; \
    mkdir nginx; \
    tar -xzf nginx.tar.gz -C nginx --strip-components=1; \
    cd nginx; \
    source_version=$(awk '$2 == "NGINX_VERSION" { gsub(/"/, "", $3); print $3 }' src/core/nginx.h); \
    binary_version=$(nginx -v 2>&1); \
    if [ "$binary_version" != "nginx version: nginx/${source_version}" ]; then \
        printf 'NGINX version mismatch: source=%s binary=%s\n' "$source_version" "$binary_version" >&2; \
        exit 1; \
    fi; \
    ./configure --with-compat --add-dynamic-module=/tmp/build/modsecurity-nginx; \
    make modules -j"$(getconf _NPROCESSORS_ONLN)"; \
    install -D -m 0755 objs/ngx_http_modsecurity_module.so /tmp/ngx_http_modsecurity_module.so

RUN set -eux; \
    curl -fsSLo coreruleset.tar.gz \
        "https://github.com/coreruleset/coreruleset/releases/download/${OWASP_CRS_VERSION}/coreruleset-${OWASP_CRS_VERSION#v}-minimal.tar.gz"; \
    echo "${OWASP_CRS_SHA256}  coreruleset.tar.gz" | sha256sum -c -; \
    mkdir /tmp/coreruleset; \
    tar -xzf coreruleset.tar.gz -C /tmp/coreruleset --strip-components=1

FROM ${NGINX_IMAGE}

ARG IMAGE_VERSION=dev
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.title="Docker NGINX by Prowect" \
      org.opencontainers.image.description="Production-hardened NGINX image with ModSecurity and OWASP CRS" \
      org.opencontainers.image.authors="office@prowect.com" \
      org.opencontainers.image.source="https://github.com/Prowect/Docker-NGINX" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}"

ENV NGINX_PORT=80 \
    MODSECURITY_ENGINE=On \
    MODSEC_AUDIT_LOG_PARTS=ABFHZ \
    MODSEC_AUDIT_RETENTION_DAYS=30 \
    MODSEC_AUDIT_MAX_SIZE_MB=0 \
    MODSEC_AUDIT_MAX_SIZE_GB=1 \
    MODSEC_AUDIT_CLEANUP_INTERVAL_SECONDS=86400 \
    MODSEC_REQUEST_BODY_LIMIT=10485760 \
    MODSEC_REQUEST_BODY_NO_FILES_LIMIT=1048576 \
    CRS_BLOCKING_PARANOIA_LEVEL=1 \
    CRS_DETECTION_PARANOIA_LEVEL=1 \
    CRS_INBOUND_ANOMALY_THRESHOLD=5 \
    CRS_OUTBOUND_ANOMALY_THRESHOLD=4 \
    TRUSTED_PROXY_CIDRS= \
    REAL_IP_HEADER=X-Forwarded-For \
    REAL_IP_RECURSIVE=on \
    RATE_LIMIT_ZONE_NAME=perip \
    RATE_LIMIT_ZONE_SIZE=10m \
    RATE_LIMIT_RATE=10r/s \
    RATE_LIMIT_BURST=20 \
    RATE_LIMIT_STATUS=429 \
    CLIENT_MAX_BODY_SIZE=10m \
    KEEPALIVE_TIMEOUT=65 \
    CLIENT_BODY_TIMEOUT=60 \
    CLIENT_HEADER_TIMEOUT=60 \
    SEND_TIMEOUT=60 \
    PROXY_CONNECT_TIMEOUT=5 \
    PROXY_READ_TIMEOUT=60 \
    PROXY_SEND_TIMEOUT=60

RUN set -eux; \
    apk add --no-cache \
        ca-certificates \
        geoip \
        gettext-envsubst \
        libmaxminddb-libs \
        libstdc++ \
        libxml2 \
        lmdb \
        pcre2 \
        yajl \
        zlib; \
    rm -f /etc/nginx/conf.d/default.conf; \
    mkdir -p \
        /etc/nginx/modsec/custom \
        /usr/local/modsecurity/lib \
        /var/cache/nginx \
        /var/log/modsecurity/audit/storage; \
    chown -R nginx:nginx \
        /var/cache/nginx \
        /var/log/modsecurity

COPY --from=builder /usr/local/modsecurity/lib/ /usr/local/modsecurity/lib/
COPY --from=builder /tmp/ngx_http_modsecurity_module.so /usr/lib/nginx/modules/ngx_http_modsecurity_module.so
COPY --from=builder /tmp/coreruleset/ /etc/nginx/modsec/coreruleset/
COPY --from=builder /tmp/modsecurity.conf /etc/nginx/modsec/modsecurity.conf
COPY --from=builder /tmp/unicode.mapping /etc/nginx/modsec/unicode.mapping

COPY config/nginx/nginx.conf /etc/nginx/nginx.conf
COPY config/nginx/templates/ /etc/nginx/templates/
COPY config/modsecurity/ /etc/nginx/modsec/custom/
COPY service/container-entrypoint.sh /usr/local/bin/container-entrypoint
COPY service/render-runtime-config.sh /usr/local/bin/render-runtime-config
COPY service/modsec-cleanup.sh /usr/local/bin/modsec-cleanup
COPY www/ /usr/share/nginx/html/

RUN set -eux; \
    rm -f /usr/local/modsecurity/lib/*.a /usr/local/modsecurity/lib/*.la; \
    cp /etc/nginx/modsec/coreruleset/crs-setup.conf.example /etc/nginx/modsec/coreruleset/crs-setup.conf; \
    sed -i 's|^[[:space:]]*SecUnicodeMapFile[[:space:]].*|SecUnicodeMapFile /etc/nginx/modsec/unicode.mapping 20127|' /etc/nginx/modsec/modsecurity.conf; \
    sed -i 's/^SecRuleEngine.*/SecRuleEngine DetectionOnly/' /etc/nginx/modsec/modsecurity.conf; \
    sed -i 's/^SecAuditEngine.*/SecAuditEngine RelevantOnly/' /etc/nginx/modsec/modsecurity.conf; \
    sed -i 's/^SecAuditLogType.*/SecAuditLogType Concurrent/' /etc/nginx/modsec/modsecurity.conf; \
    sed -i 's|^SecAuditLog .*|SecAuditLog /var/log/modsecurity/audit/audit.log|' /etc/nginx/modsec/modsecurity.conf; \
    sed -i 's/^SecAuditLogParts.*/SecAuditLogParts ABFHZ/' /etc/nginx/modsec/modsecurity.conf; \
    printf '\nSecAuditLogStorageDir /var/log/modsecurity/audit/storage\n' >> /etc/nginx/modsec/modsecurity.conf; \
    printf '%s\n' \
        'Include /etc/nginx/modsec/modsecurity.conf' \
        'Include /tmp/modsecurity-runtime.conf' \
        'Include /etc/nginx/modsec/coreruleset/crs-setup.conf' \
        'Include /etc/nginx/modsec/custom/*-before.conf' \
        'Include /etc/nginx/modsec/coreruleset/plugins/*-config.conf' \
        'Include /etc/nginx/modsec/coreruleset/plugins/*-before.conf' \
        'Include /etc/nginx/modsec/coreruleset/rules/*.conf' \
        'Include /etc/nginx/modsec/coreruleset/plugins/*-after.conf' \
        'Include /etc/nginx/modsec/custom/*-after.conf' \
        > /etc/nginx/modsec/main.conf; \
    chmod 0755 \
        /usr/local/bin/container-entrypoint \
        /usr/local/bin/render-runtime-config \
        /usr/local/bin/modsec-cleanup; \
    chmod 0750 /var/log/modsecurity/audit /var/log/modsecurity/audit/storage; \
    chown -R nginx:nginx /var/log/modsecurity

USER nginx

EXPOSE 80

VOLUME ["/var/log/modsecurity/audit"]

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD busybox nc -z -w 2 127.0.0.1 "${NGINX_PORT}" || exit 1

STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/local/bin/container-entrypoint"]
CMD ["serve"]

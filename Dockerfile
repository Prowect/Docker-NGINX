FROM nginx:1.31.3-alpine

ARG MODSECURITY_VERSION=v3.0.16
ARG MODSECURITY_NGINX_VERSION=v1.0.4
ARG OWASP_CRS_VERSION=v4.28.0

LABEL org.opencontainers.image.title="Docker NGINX by Prowect"
LABEL org.opencontainers.image.description="Docker image for preconfigured NGINX"
LABEL org.opencontainers.image.authors="office@prowect.com"
LABEL org.opencontainers.image.source="https://github.com/Prowect/Docker-NGINX"

# Default: enable ModSecurity WAF engine
ENV MODSECURITY_ENGINE=On

# Default retention for ModSecurity audit storage (days)
ENV MODSEC_AUDIT_RETENTION_DAYS=30
# Optional maximum size for ModSecurity audit storage
ENV MODSEC_AUDIT_MAX_SIZE_MB=0
ENV MODSEC_AUDIT_MAX_SIZE_GB=1

# Default rate limit (per IP) configuration
ENV RATE_LIMIT_ZONE_NAME=perip
ENV RATE_LIMIT_ZONE_SIZE=10m
ENV RATE_LIMIT_RATE=10r/s
ENV RATE_LIMIT_BURST=20
ENV RATE_LIMIT_STATUS=429

# Defaults for NGINX timeouts and sizes (ENV-overridable)
ENV CLIENT_MAX_BODY_SIZE=10m
ENV KEEPALIVE_TIMEOUT=65
ENV CLIENT_BODY_TIMEOUT=60
ENV CLIENT_HEADER_TIMEOUT=60
ENV SEND_TIMEOUT=60
ENV PROXY_CONNECT_TIMEOUT=5
ENV PROXY_READ_TIMEOUT=60
ENV PROXY_SEND_TIMEOUT=60

# Build and install ModSecurity v3 and the NGINX ModSecurity connector from source (keeps Alpine base)
RUN set -eux; \
        apk update; \
        # Runtime deps
        apk add --no-cache \
            ca-certificates \
            curl \
            git \
            pcre2 \
            libxml2 \
            yajl \
            lmdb \
            geoip \
            libmaxminddb \
            openssl \
            zlib \
            libstdc++ \
            vim \
            jq \
            runit; \
        # Build deps
        apk add --no-cache --virtual .build-deps \
            build-base \
            automake \
            autoconf \
            libtool \
            pkgconfig \
            pcre2-dev \
            libxml2-dev \
            yajl-dev \
            lmdb-dev \
            geoip-dev \
            libmaxminddb-dev \
            openssl-dev \
            zlib-dev \
            linux-headers \
            wget \
            tar; \
        # Build libModSecurity (v3)
        git clone --depth 1 --branch "${MODSECURITY_VERSION}" https://github.com/owasp-modsecurity/ModSecurity /tmp/ModSecurity; \
        cd /tmp/ModSecurity; \
        git submodule update --init --recursive; \
        ./build.sh; \
        ./configure; \
        make -j"$(getconf _NPROCESSORS_ONLN)"; \
        make install; \
        ldconfig || true; \
        # Build NGINX ModSecurity connector as dynamic module matching the bundled NGINX version
        git clone --depth 1 --branch "${MODSECURITY_NGINX_VERSION}" https://github.com/owasp-modsecurity/ModSecurity-nginx /tmp/ModSecurity-nginx; \
        NGINX_VER="$(nginx -v 2>&1 | awk -F/ '{print $2}')"; \
        wget -O /tmp/nginx.tar.gz "https://nginx.org/download/nginx-${NGINX_VER}.tar.gz"; \
        mkdir -p /tmp/ngsrc; \
        tar -xzf /tmp/nginx.tar.gz -C /tmp/ngsrc; \
        cd /tmp/ngsrc/nginx-*; \
        ./configure --with-compat --add-dynamic-module=/tmp/ModSecurity-nginx; \
        make modules -j"$(getconf _NPROCESSORS_ONLN)"; \
        mkdir -p /usr/lib/nginx/modules; \
        cp objs/ngx_http_modsecurity_module.so /usr/lib/nginx/modules/; \
        # Create ModSecurity directory structure and fetch OWASP CRS
        mkdir -p /etc/nginx/modsec; \
        git clone --depth 1 --branch "${OWASP_CRS_VERSION}" https://github.com/coreruleset/coreruleset /etc/nginx/modsec/coreruleset; \
        cp /etc/nginx/modsec/coreruleset/crs-setup.conf.example /etc/nginx/modsec/coreruleset/crs-setup.conf; \
        # Get a recommended ModSecurity v3 base config and turn engine ON
        curl -sSL "https://raw.githubusercontent.com/owasp-modsecurity/ModSecurity/${MODSECURITY_VERSION}/modsecurity.conf-recommended" -o /etc/nginx/modsec/modsecurity.conf; \
        # Fetch unicode.mapping required by SecUnicodeMapFile and set absolute path
            curl -sSL "https://raw.githubusercontent.com/owasp-modsecurity/ModSecurity/${MODSECURITY_VERSION}/unicode.mapping" -o /etc/nginx/modsec/unicode.mapping; \
            sed -i 's|^[[:space:]]*SecUnicodeMapFile[[:space:]].*|SecUnicodeMapFile /etc/nginx/modsec/unicode.mapping 20127|' /etc/nginx/modsec/modsecurity.conf; \
        # Ensure WAF blocks (not just detects)
        sed -i 's/^SecRuleEngine.*/SecRuleEngine On/' /etc/nginx/modsec/modsecurity.conf; \
        # Log only relevant requests (those that trigger rules)
            # Configure Audit Log in JSON and write into a directory for volume mounting
                mkdir -p /var/log/modsecurity/audit; \
                chown -R nginx:nginx /var/log/modsecurity; \
                sed -i 's/^SecAuditEngine.*/SecAuditEngine RelevantOnly/' /etc/nginx/modsec/modsecurity.conf; \
                # Use Concurrent to write one file per request
                sed -i 's/^SecAuditLogType.*/SecAuditLogType Concurrent/' /etc/nginx/modsec/modsecurity.conf; \
                # Index file (ModSecurity requires SecAuditLog also in Concurrent mode)
                sed -i 's|^SecAuditLog .*|SecAuditLog /var/log/modsecurity/audit/audit.log|' /etc/nginx/modsec/modsecurity.conf; \
                # Storage directory for per-request JSON files
                mkdir -p /var/log/modsecurity/audit/storage; \
                chown -R nginx:nginx /var/log/modsecurity/audit/storage; \
                if grep -q '^SecAuditLogStorageDir' /etc/nginx/modsec/modsecurity.conf; then \
                    sed -i 's|^SecAuditLogStorageDir.*|SecAuditLogStorageDir /var/log/modsecurity/audit/storage|' /etc/nginx/modsec/modsecurity.conf; \
                else \
                    echo 'SecAuditLogStorageDir /var/log/modsecurity/audit/storage' >> /etc/nginx/modsec/modsecurity.conf; \
                fi; \
                # Include request body (C) in audit parts
                if grep -q '^SecAuditLogParts' /etc/nginx/modsec/modsecurity.conf; then \
                    sed -i 's|^SecAuditLogParts.*|SecAuditLogParts ABCIJDEFHZ|' /etc/nginx/modsec/modsecurity.conf; \
                else \
                    echo 'SecAuditLogParts ABCIJDEFHZ' >> /etc/nginx/modsec/modsecurity.conf; \
                fi; \
                # Ensure ModSecurity can read request bodies
                if grep -q '^SecRequestBodyAccess' /etc/nginx/modsec/modsecurity.conf; then \
                    sed -i 's|^SecRequestBodyAccess.*|SecRequestBodyAccess On|' /etc/nginx/modsec/modsecurity.conf; \
                else \
                    echo 'SecRequestBodyAccess On' >> /etc/nginx/modsec/modsecurity.conf; \
                fi; \
                if grep -q '^SecAuditLogFormat' /etc/nginx/modsec/modsecurity.conf; then \
                    sed -i 's/^SecAuditLogFormat.*/SecAuditLogFormat JSON/' /etc/nginx/modsec/modsecurity.conf; \
                else \
                    echo 'SecAuditLogFormat JSON' >> /etc/nginx/modsec/modsecurity.conf; \
                fi; \
        # Create main rules file that includes base config + CRS
        printf "Include /etc/nginx/modsec/modsecurity.conf\nInclude /etc/nginx/modsec/coreruleset/crs-setup.conf\nInclude /etc/nginx/modsec/coreruleset/rules/*.conf\n" > /etc/nginx/modsec/main.conf; \
        # Ensure the ModSecurity module is loaded by NGINX at startup (prepend line without sed flags pitfalls)
        printf 'load_module /usr/lib/nginx/modules/ngx_http_modsecurity_module.so;\n' | cat - /etc/nginx/nginx.conf > /tmp/nginx.conf; \
        mv /tmp/nginx.conf /etc/nginx/nginx.conf; \
        # Cleanup build artifacts and deps
        apk del .build-deps; \
        rm -rf /var/cache/apk/* /tmp/* /root/.cache

# Copy custom NGINX configuration file
COPY config/nginx/nginx.conf /etc/nginx/nginx.conf

# Copy templates
COPY config/nginx/templates/ /etc/nginx/templates/

# Runit services for nginx
COPY service/nginx.service /etc/service/nginx/run
RUN chmod +x /etc/service/nginx/run

# Runit service for periodic ModSecurity audit cleanup
COPY service/modsec-cleanup.service /etc/service/modsec-cleanup/run
RUN chmod +x /etc/service/modsec-cleanup/run

COPY www/ /usr/share/nginx/html

# Expose audit log directory as a volume for persistence
VOLUME ["/var/log/modsecurity/audit"]

# Start runit supervisor to manage nginx services
CMD ["runsvdir", "-P", "/etc/service"]

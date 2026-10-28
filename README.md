# Docker NGINX with ModSecurity WAF

Production-hardened, Alpine-based NGINX image with ModSecurity v3 and the OWASP Core Rule Set (CRS). The image runs as an unprivileged user, supports a read-only root filesystem, validates runtime configuration and shuts down gracefully.

## Included versions

- NGINX 1.31.8 on Alpine 3.24 (slim)
- ModSecurity 3.0.17
- ModSecurity-nginx 1.0.4
- OWASP CRS 4.30.0

All source archives are verified with SHA-256 during the build. The NGINX base image is pinned to an immutable multi-architecture digest. The module build checks that the downloaded NGINX source version matches the installed NGINX binary.

## Quick start

```bash
docker build -t nginx-waf .
docker run --rm -p 8080:80 nginx-waf
```

Open <http://localhost:8080>. The health endpoint is available at <http://localhost:8080/healthz>.

The container remains compatible with the established internal port `80` and runs as UID/GID `101` (`nginx`). Docker normally permits unprivileged low ports inside containers; the hardened Compose configuration makes this explicit with the namespaced `net.ipv4.ip_unprivileged_port_start=0` sysctl.

## Security model

- Unprivileged runtime user
- Read-only-root-filesystem compatible
- No effective Linux capabilities in the hardened Compose deployment
- Built-in healthcheck
- Graceful NGINX shutdown through PID 1 signal forwarding
- Minimal multi-stage runtime image without compilers, Git, editors or source trees
- Request-body and CRS limits with validated environment variables
- Audit logs exclude request and response bodies by default (`ABFHZ`)
- Application-specific CRS exclusion files are supported

TLS should normally terminate at a trusted ingress, load balancer or reverse proxy. When exposing this container directly, mount a dedicated TLS server configuration and certificates instead.

## Configuration

| Environment variable | Default | Description |
|---|---:|---|
| `NGINX_PORT` | `80` | Listen port, between 1 and 65535 |
| `MODSECURITY_ENGINE` | `On` | `On`, `DetectionOnly` or `Off` |
| `MODSEC_AUDIT_LOG_PARTS` | `ABFHZ` | Uppercase ModSecurity audit parts |
| `MODSEC_AUDIT_RETENTION_DAYS` | `30` | Audit file retention |
| `MODSEC_AUDIT_MAX_SIZE_MB` | `0` | Audit storage limit in MB; `0` uses the GB value |
| `MODSEC_AUDIT_MAX_SIZE_GB` | `1` | Audit storage limit in GB |
| `MODSEC_AUDIT_CLEANUP_INTERVAL_SECONDS` | `86400` | Cleanup interval; defaults to once per day |
| `MODSEC_REQUEST_BODY_LIMIT` | `10485760` | Maximum buffered request body in bytes |
| `MODSEC_REQUEST_BODY_NO_FILES_LIMIT` | `1048576` | Maximum non-file request body in bytes |
| `CRS_BLOCKING_PARANOIA_LEVEL` | `1` | Blocking paranoia level, 1–4 |
| `CRS_DETECTION_PARANOIA_LEVEL` | `1` | Detection paranoia level, 1–4 and not below blocking level |
| `CRS_INBOUND_ANOMALY_THRESHOLD` | `5` | Inbound blocking threshold |
| `CRS_OUTBOUND_ANOMALY_THRESHOLD` | `4` | Outbound blocking threshold |
| `TRUSTED_PROXY_CIDRS` | empty | Space-separated trusted proxy CIDRs |
| `REAL_IP_HEADER` | `X-Forwarded-For` | `X-Forwarded-For` or `X-Real-IP` |
| `REAL_IP_RECURSIVE` | `on` | Recursive trusted-proxy evaluation |
| `RATE_LIMIT_ZONE_NAME` | `perip` | Rate-limit zone name |
| `RATE_LIMIT_ZONE_SIZE` | `10m` | Rate-limit shared-memory size |
| `RATE_LIMIT_RATE` | `10r/s` | Requests per second or minute |
| `RATE_LIMIT_BURST` | `20` | Allowed burst |
| `RATE_LIMIT_STATUS` | `429` | Rate-limit response status |
| `CLIENT_MAX_BODY_SIZE` | `10m` | NGINX client request limit |
| `KEEPALIVE_TIMEOUT` | `65` | Keepalive timeout in seconds |
| `CLIENT_BODY_TIMEOUT` | `60` | Client body timeout in seconds |
| `CLIENT_HEADER_TIMEOUT` | `60` | Client header timeout in seconds |
| `SEND_TIMEOUT` | `60` | Response send timeout in seconds |
| `PROXY_CONNECT_TIMEOUT` | `5` | Upstream connect timeout in seconds |
| `PROXY_READ_TIMEOUT` | `60` | Upstream read timeout in seconds |
| `PROXY_SEND_TIMEOUT` | `60` | Upstream send timeout in seconds |

Invalid values fail fast before NGINX starts.

## Reverse proxies and rate limiting

Without `TRUSTED_PROXY_CIDRS`, rate limiting uses the direct peer address. Behind a proxy, explicitly trust only the proxy network:

```yaml
environment:
  TRUSTED_PROXY_CIDRS: "10.0.0.0/8 192.168.0.0/16"
  REAL_IP_HEADER: X-Forwarded-For
  REAL_IP_RECURSIVE: "on"
```

Never trust arbitrary client-provided forwarding headers or `0.0.0.0/0`.

## WAF rollout and tuning

For a new application, first run with `MODSECURITY_ENGINE=DetectionOnly`, review false positives and add narrow exclusions. Then enable blocking with `MODSECURITY_ENGINE=On`.

Custom exclusions are loaded from:

- `/etc/nginx/modsec/custom/*-before.conf` before CRS rules
- `/etc/nginx/modsec/custom/*-after.conf` after CRS rules

Two documented placeholder files are included under `config/modsecurity/`. Keep custom rule IDs in the application-owned range and test every exclusion.

## Audit logs and privacy

Audit logs are stored under `/var/log/modsecurity/audit`. The default `ABFHZ` parts intentionally omit request and response bodies. Headers and rule messages may still contain sensitive values; restrict filesystem access, encrypt persistent storage and forward only the minimum required data.

When using Linux bind mounts, ensure UID/GID `101` can write the audit and cache directories:

```bash
sudo chown -R 101:101 data/logs/modsecurity/audit data/cache
```

## Hardened Compose deployment

The included `docker-compose.yml` enables:

- Read-only root filesystem
- All Linux capabilities dropped
- Explicit unprivileged-port sysctl for the compatible internal port 80
- `no-new-privileges`
- Writable `/tmp` tmpfs
- Healthcheck and graceful stop period
- CPU, memory and PID limits

For production, deploy an immutable image digest instead of building locally:

```yaml
image: prowect/nginx@sha256:<published-digest>
```

Adjust resource limits based on load tests. ModSecurity memory usage depends strongly on concurrency, body sizes and enabled CRS paranoia levels.

## Custom NGINX configuration

Templates in `/etc/nginx/templates/*.template` are rendered at startup into `/tmp/nginx-runtime/conf.d`. Additional static `.conf` files can be mounted read-only under `/etc/nginx/conf.d`.

Existing mounted `conf.d` files and templates that listen on port `80` remain supported. Configuration and certificate files must be readable by UID/GID `101`. A complete replacement of `nginx.conf` must keep PID, cache and temporary paths writable for the non-root user; `/tmp` and `/var/cache/nginx` are prepared for this purpose.

The built-in `/healthz` endpoint bypasses WAF, access logging and rate limiting. Keep it limited to internal health probes at the network layer.

## Build and tests

```bash
docker compose build --pull nginx
./run-tests.sh docker-nginx-nginx
```

Before releasing an update, build and test both supported architectures:

```bash
for arch in amd64 arm64; do
  docker buildx build --pull --platform "linux/$arch" --load -t "docker-nginx:test-$arch" .
  DOCKER_DEFAULT_PLATFORM="linux/$arch" ./run-tests.sh "docker-nginx:test-$arch"
done
```

Running the non-native architecture requires emulation (included with Docker Desktop).

The integration test covers:

- Non-root and image-size guardrails
- Read-only runtime with all capabilities dropped
- Healthcheck and normal HTTP traffic
- CRS blocking of XSS and SQL-injection payloads
- The same XSS payload passes in `DetectionOnly` and `Off` modes
- NGINX and ModSecurity request-body limits
- Per-client rate limiting with HTTP 429
- Trusted proxy address handling
- Mounted legacy `conf.d` configuration on port 80
- Age- and size-based audit cleanup with storage-root preservation
- Graceful shutdown with exit code 0
- Rejection of invalid runtime configuration

## Release supply chain

Pull requests and `main` builds only build, test and scan. Only version tags publish images. Published multi-architecture images include SBOM and provenance attestations and are signed keylessly with Cosign. CI explicitly pins Trivy 0.76.1 and Cosign 3.1.4; the vulnerability gate rejects fixable HIGH and CRITICAL findings.

Verify a released digest:

```bash
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/Prowect/Docker-NGINX/\.github/workflows/docker-image\.yml@refs/tags/v[0-9].*$' \
  prowect/nginx@sha256:<published-digest>
```

Dependabot monitors the pinned base image and GitHub Actions. Update the NGINX image digest, source version and source checksum together. Updates to ModSecurity, its connector and CRS should retain explicit SHA-256 verification and pass the full integration suite on both architectures before release. Review the pinned Trivy and Cosign versions as well as their installer Actions. Check application traffic in staging for new CRS false positives before production rollout.

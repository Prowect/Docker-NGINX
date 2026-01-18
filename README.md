# Docker NGINX with ModSecurity WAF

An Alpine-based NGINX image preconfigured with ModSecurity v3 (OWASP Core Rule Set), sane defaults for rate limiting and timeouts, and a built-in background service that keeps ModSecurity audit logs tidy. The image uses the official NGINX Docker entrypoint to render configuration from environment-aware templates, so you can tune behavior with environment variables—no manual config editing required.

## Features
- ModSecurity v3 compiled and enabled, including OWASP CRS (blocking by default)
- Rate limiting per client IP via `limit_req`
- Environment-driven timeouts and request size limits
- Runit-managed services: NGINX and audit log cleanup
- Persistent audit logs under `/var/log/modsecurity/audit` (volume-ready)
- Configuration templating via `/etc/nginx/templates/*.template`

## How it works
- At container start, the official NGINX entrypoint processes templates in `/etc/nginx/templates/` (like `default.conf.template`) and writes rendered configs to `/etc/nginx/conf.d/` using environment variables.
- ModSecurity is loaded as a dynamic NGINX module and configured through `/etc/nginx/modsec/main.conf`.
- The cleanup service prunes old or excess ModSecurity audit records based on retention days and an optional size cap.

## Quick Start

```bash
docker build -t nginx-waf .
docker run --rm -p 8080:80 \
	-v $(pwd)/data/logs/modsecurity/audit:/var/log/modsecurity/audit \
	--name nginx-waf nginx-waf
```

Open http://localhost:8080 to view the default site.

## Configuration via Environment Variables

The following environment variables influence runtime behavior. Unless stated otherwise, all are read and applied during startup by the template system.

| Environment variable          | Default value | Possible values               | Description |
|-------------------------------|---------------|-------------------------------|-------------|
| `MODSECURITY_ENGINE`          | `On`          | `On`, `DetectionOnly`, `Off`  | ModSecurity rule engine mode. `On` blocks; `DetectionOnly` logs without blocking; `Off` disables WAF. |
| `MODSEC_AUDIT_RETENTION_DAYS` | `30`          | integer ≥ 0                   | Days to keep per-request audit entries under `/var/log/modsecurity/audit/storage`. |
| `MODSEC_AUDIT_MAX_SIZE_MB`    | `0`           | integer ≥ 0                   | Max size (MB) for audit storage; `0` disables MB cap. If `0` and `MODSEC_AUDIT_MAX_SIZE_GB` > 0, GB is converted to MB. |
| `MODSEC_AUDIT_MAX_SIZE_GB`    | `1`           | integer ≥ 0                   | Alternative cap (GB). Used only if `MODSEC_AUDIT_MAX_SIZE_MB` is `0`. Default effectively enforces ~1GB cap. |
| `RATE_LIMIT_ZONE_NAME`        | `perip`       | string                        | Name of the `limit_req` zone keyed by client IP. |
| `RATE_LIMIT_ZONE_SIZE`        | `10m`         | NGINX shared memory size      | Size of the rate limit zone (e.g., `10m`). |
| `RATE_LIMIT_RATE`             | `10r/s`       | NGINX rate format             | Allowed request rate per client (e.g., `10r/s`). |
| `RATE_LIMIT_BURST`            | `20`          | integer                       | Burst capacity before limiting is applied. |
| `RATE_LIMIT_STATUS`           | `429`         | valid HTTP status code        | Status code returned when rate limit is triggered. |
| `CLIENT_MAX_BODY_SIZE`        | `10m`         | NGINX size format             | Maximum allowed client request body size. |
| `KEEPALIVE_TIMEOUT`           | `65`          | seconds                       | Keepalive timeout for client connections. |
| `CLIENT_BODY_TIMEOUT`         | `60`          | seconds                       | Timeout for reading client request body. |
| `CLIENT_HEADER_TIMEOUT`       | `60`          | seconds                       | Timeout for reading client request headers. |
| `SEND_TIMEOUT`                | `60`          | seconds                       | Timeout for sending a response to the client. |
| `PROXY_CONNECT_TIMEOUT`       | `5`           | seconds                       | Upstream proxy connect timeout (effective in proxy locations). |
| `PROXY_READ_TIMEOUT`          | `60`          | seconds                       | Upstream proxy read timeout. |
| `PROXY_SEND_TIMEOUT`          | `60`          | seconds                       | Upstream proxy send timeout. |


## Volumes and Persistence
- Audit logs: mount a host directory to `/var/log/modsecurity/audit` to persist per-request JSON audit files.
- Cache (optional): mount a host directory to `/var/cache/nginx` if you rely on NGINX caching.

## Example docker-compose (Development)

```yaml
version: '3.8'

services:
	nginx:
		image: prowect/nginx
		environment:
			MODSECURITY_ENGINE: DetectionOnly
			RATE_LIMIT_RATE: 10r/s
			RATE_LIMIT_BURST: 20
			CLIENT_MAX_BODY_SIZE: 10m
		ports:
			- "8080:80"
		volumes:
			- ./www:/usr/share/nginx/html
			- ./data/logs/modsecurity/audit:/var/log/modsecurity/audit
			- ./data/cache:/var/cache/nginx
```

## Example docker-compose (Production)

```yaml
version: '3.8'

services:
	nginx:
		image: prowect/nginx
		restart: unless-stopped
		environment:
			MODSECURITY_ENGINE: On
			RATE_LIMIT_RATE: 10r/s
			RATE_LIMIT_BURST: 20
			RATE_LIMIT_STATUS: 429
			CLIENT_MAX_BODY_SIZE: 10m
			MODSEC_AUDIT_RETENTION_DAYS: 30
			MODSEC_AUDIT_MAX_SIZE_GB: 1
		ports:
			- "80:80"
		volumes:
			- ./data/logs/modsecurity/audit:/var/log/modsecurity/audit
			- ./data/cache:/var/cache/nginx
```

## Customizing NGINX
- Add or modify templates under `/etc/nginx/templates/` (in this repo: `config/nginx/templates/`). They are rendered on startup with environment substitutions.
- For advanced setups (proxying, upstreams, HTTPS), create new template files with appropriate `server` and `location` blocks.

## ModSecurity exceptions in templates
You can define exceptions per path (location) directly inside a template using `modsecurity_rules`. Below are common patterns:

1) Disable WAF for a specific endpoint (e.g., health checks)

```nginx
server {
	listen 80;
	server_name localhost;

	location /health {
		# Turn off ModSecurity for this path
		modsecurity off;
		return 200 "OK\n";
	}
}
```

2) Remove specific CRS rule IDs for one route

```nginx
server {
	listen 80;
	server_name localhost;

	location /api/upload {
		modsecurity on;
		modsecurity_rules '
			Include /etc/nginx/modsec/main.conf
			SecRuleEngine ${MODSECURITY_ENGINE}

			# Example: relax protocol/body checks for uploads
			SecRuleRemoveById 920230 920400 920420

			# Narrow a rule target (exclude arg "payload" from rule 942100)
			SecRuleUpdateTargetById 942100 !ARGS:payload
		';

		# e.g., proxy to your backend
		# proxy_pass http://backend;
	}
}
```

3) Whitelist a trusted IP by turning the engine off for that client

```nginx
server {
	listen 80;
	server_name localhost;

	location / {
		modsecurity on;
		modsecurity_rules '
			Include /etc/nginx/modsec/main.conf
			SecRuleEngine ${MODSECURITY_ENGINE}

			# Disable WAF for a specific IP (transaction-level)
			SecRule REMOTE_ADDR "@ipMatch 203.0.113.10" \
				"id:100000,phase:1,pass,ctl:ruleEngine=Off"
		';

		root /usr/share/nginx/html;
		index index.html;
	}
}
```

Place such snippets in a new template file (e.g., `config/nginx/templates/custom.conf.template`). On startup, the entrypoint renders templates and includes them under `/etc/nginx/conf.d/`.
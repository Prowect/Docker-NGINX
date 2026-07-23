#!/usr/bin/env sh
set -eu

RUNTIME_ROOT="${NGINX_RUNTIME_ROOT:-/tmp/nginx-runtime}"
NGINX_RUNTIME_CONF_DIR="$RUNTIME_ROOT/conf.d"
MODSEC_RUNTIME_CONF="/tmp/modsecurity-runtime.conf"

require_uint() {
    name="$1"
    value="$2"
    case "$value" in
        ''|*[!0-9]*)
            printf '[entrypoint] %s must be a non-negative integer, got: %s\n' "$name" "$value" >&2
            exit 1
            ;;
    esac
}

require_range() {
    name="$1"
    value="$2"
    minimum="$3"
    maximum="$4"
    require_uint "$name" "$value"
    if [ "$value" -lt "$minimum" ] || [ "$value" -gt "$maximum" ]; then
        printf '[entrypoint] %s must be between %s and %s, got: %s\n' \
            "$name" "$minimum" "$maximum" "$value" >&2
        exit 1
    fi
}

require_regex() {
    name="$1"
    value="$2"
    pattern="$3"
    if ! printf '%s\n' "$value" | grep -Eq "$pattern"; then
        printf '[entrypoint] invalid %s value: %s\n' "$name" "$value" >&2
        exit 1
    fi
}

engine="${MODSECURITY_ENGINE:-On}"
audit_parts="${MODSEC_AUDIT_LOG_PARTS:-ABFHZ}"
blocking_pl="${CRS_BLOCKING_PARANOIA_LEVEL:-1}"
detection_pl="${CRS_DETECTION_PARANOIA_LEVEL:-1}"
inbound_threshold="${CRS_INBOUND_ANOMALY_THRESHOLD:-5}"
outbound_threshold="${CRS_OUTBOUND_ANOMALY_THRESHOLD:-4}"
request_body_limit="${MODSEC_REQUEST_BODY_LIMIT:-10485760}"
request_body_no_files_limit="${MODSEC_REQUEST_BODY_NO_FILES_LIMIT:-1048576}"
audit_retention_days="${MODSEC_AUDIT_RETENTION_DAYS:-30}"
audit_max_size_mb="${MODSEC_AUDIT_MAX_SIZE_MB:-0}"
audit_max_size_gb="${MODSEC_AUDIT_MAX_SIZE_GB:-1}"
audit_cleanup_interval="${MODSEC_AUDIT_CLEANUP_INTERVAL_SECONDS:-86400}"

require_range NGINX_PORT "${NGINX_PORT:-80}" 1 65535
require_regex RATE_LIMIT_ZONE_NAME "${RATE_LIMIT_ZONE_NAME:-perip}" '^[A-Za-z][A-Za-z0-9_]*$'
require_regex RATE_LIMIT_ZONE_SIZE "${RATE_LIMIT_ZONE_SIZE:-10m}" '^[1-9][0-9]*[kKmM]$'
require_regex RATE_LIMIT_RATE "${RATE_LIMIT_RATE:-10r/s}" '^[1-9][0-9]*r/[sm]$'
require_range RATE_LIMIT_BURST "${RATE_LIMIT_BURST:-20}" 1 1000000
require_range RATE_LIMIT_STATUS "${RATE_LIMIT_STATUS:-429}" 400 599
require_regex CLIENT_MAX_BODY_SIZE "${CLIENT_MAX_BODY_SIZE:-10m}" '^[1-9][0-9]*[kKmMgG]?$'
require_uint KEEPALIVE_TIMEOUT "${KEEPALIVE_TIMEOUT:-65}"
require_uint CLIENT_BODY_TIMEOUT "${CLIENT_BODY_TIMEOUT:-60}"
require_uint CLIENT_HEADER_TIMEOUT "${CLIENT_HEADER_TIMEOUT:-60}"
require_uint SEND_TIMEOUT "${SEND_TIMEOUT:-60}"
require_uint PROXY_CONNECT_TIMEOUT "${PROXY_CONNECT_TIMEOUT:-5}"
require_uint PROXY_READ_TIMEOUT "${PROXY_READ_TIMEOUT:-60}"
require_uint PROXY_SEND_TIMEOUT "${PROXY_SEND_TIMEOUT:-60}"

case "$engine" in
    On|Off|DetectionOnly) ;;
    *)
        printf '[entrypoint] MODSECURITY_ENGINE must be On, Off, or DetectionOnly, got: %s\n' "$engine" >&2
        exit 1
        ;;
esac

case "$audit_parts" in
    ''|*[!A-Z]*)
        printf '[entrypoint] MODSEC_AUDIT_LOG_PARTS must contain uppercase audit part letters only\n' >&2
        exit 1
        ;;
esac

require_range CRS_BLOCKING_PARANOIA_LEVEL "$blocking_pl" 1 4
require_range CRS_DETECTION_PARANOIA_LEVEL "$detection_pl" "$blocking_pl" 4
require_range CRS_INBOUND_ANOMALY_THRESHOLD "$inbound_threshold" 1 1000000
require_range CRS_OUTBOUND_ANOMALY_THRESHOLD "$outbound_threshold" 1 1000000
require_range MODSEC_REQUEST_BODY_LIMIT "$request_body_limit" 1 1073741824
require_range MODSEC_REQUEST_BODY_NO_FILES_LIMIT "$request_body_no_files_limit" 1 "$request_body_limit"
require_uint MODSEC_AUDIT_RETENTION_DAYS "$audit_retention_days"
require_uint MODSEC_AUDIT_MAX_SIZE_MB "$audit_max_size_mb"
require_uint MODSEC_AUDIT_MAX_SIZE_GB "$audit_max_size_gb"
require_range MODSEC_AUDIT_CLEANUP_INTERVAL_SECONDS "$audit_cleanup_interval" 1 31536000

mkdir -p "$NGINX_RUNTIME_CONF_DIR"
rm -f "$NGINX_RUNTIME_CONF_DIR"/*.conf

defined_envs=$(env | awk -F= '{printf "${%s} ", $1}')
for template in /etc/nginx/templates/*.template; do
    [ -f "$template" ] || continue
    output="$NGINX_RUNTIME_CONF_DIR/$(basename "${template%.template}")"
    envsubst "$defined_envs" < "$template" > "$output"
done

real_ip_conf="$NGINX_RUNTIME_CONF_DIR/00-realip.conf"
: > "$real_ip_conf"
if [ -n "${TRUSTED_PROXY_CIDRS:-}" ]; then
    case "${REAL_IP_HEADER:-X-Forwarded-For}" in
        X-Forwarded-For|X-Real-IP) ;;
        *)
            printf '[entrypoint] REAL_IP_HEADER must be X-Forwarded-For or X-Real-IP\n' >&2
            exit 1
            ;;
    esac
    case "${REAL_IP_RECURSIVE:-on}" in
        on|off) ;;
        *)
            printf '[entrypoint] REAL_IP_RECURSIVE must be on or off\n' >&2
            exit 1
            ;;
    esac

    # Intentional word splitting: TRUSTED_PROXY_CIDRS is a space-separated list.
    for cidr in ${TRUSTED_PROXY_CIDRS}; do
        case "$cidr" in
            *[!0-9A-Fa-f.:/_-]*)
                printf '[entrypoint] invalid trusted proxy CIDR: %s\n' "$cidr" >&2
                exit 1
                ;;
        esac
        printf 'set_real_ip_from %s;\n' "$cidr" >> "$real_ip_conf"
    done
    printf 'real_ip_header %s;\n' "$REAL_IP_HEADER" >> "$real_ip_conf"
    printf 'real_ip_recursive %s;\n' "$REAL_IP_RECURSIVE" >> "$real_ip_conf"
fi

umask 027
{
    printf 'SecRuleEngine %s\n' "$engine"
    printf 'SecAuditLogParts %s\n' "$audit_parts"
    printf 'SecRequestBodyLimit %s\n' "$request_body_limit"
    printf 'SecRequestBodyNoFilesLimit %s\n' "$request_body_no_files_limit"
    printf '%s\n' \
        "SecAction \"id:900000,phase:1,pass,t:none,nolog,tag:'OWASP_CRS',setvar:tx.blocking_paranoia_level=$blocking_pl\"" \
        "SecAction \"id:900001,phase:1,pass,t:none,nolog,tag:'OWASP_CRS',setvar:tx.detection_paranoia_level=$detection_pl\"" \
        "SecAction \"id:900110,phase:1,pass,t:none,nolog,tag:'OWASP_CRS',setvar:tx.inbound_anomaly_score_threshold=$inbound_threshold,setvar:tx.outbound_anomaly_score_threshold=$outbound_threshold\""
} > "$MODSEC_RUNTIME_CONF"

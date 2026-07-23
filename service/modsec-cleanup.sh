#!/usr/bin/env sh
set -eu

TARGET_DIR="/var/log/modsecurity/audit/storage"
RETENTION_DAYS="${MODSEC_AUDIT_RETENTION_DAYS:-30}"
MAX_SIZE_MB="${MODSEC_AUDIT_MAX_SIZE_MB:-0}"
MAX_SIZE_GB="${MODSEC_AUDIT_MAX_SIZE_GB:-0}"
INTERVAL_SECONDS="${MODSEC_AUDIT_CLEANUP_INTERVAL_SECONDS:-86400}"

require_uint() {
    name="$1"
    value="$2"
    case "$value" in
        ''|*[!0-9]*)
            printf '[modsec-cleanup] %s must be a non-negative integer, got: %s\n' "$name" "$value" >&2
            exit 1
            ;;
    esac
}

require_uint MODSEC_AUDIT_RETENTION_DAYS "$RETENTION_DAYS"
require_uint MODSEC_AUDIT_MAX_SIZE_MB "$MAX_SIZE_MB"
require_uint MODSEC_AUDIT_MAX_SIZE_GB "$MAX_SIZE_GB"
require_uint MODSEC_AUDIT_CLEANUP_INTERVAL_SECONDS "$INTERVAL_SECONDS"

if [ "$INTERVAL_SECONDS" -eq 0 ]; then
    printf '[modsec-cleanup] MODSEC_AUDIT_CLEANUP_INTERVAL_SECONDS must be greater than zero\n' >&2
    exit 1
fi

if [ "$MAX_SIZE_MB" -eq 0 ] && [ "$MAX_SIZE_GB" -gt 0 ]; then
    MAX_SIZE_MB=$((MAX_SIZE_GB * 1024))
fi

cleanup_once() {
    if [ ! -d "$TARGET_DIR" ]; then
        printf '[modsec-cleanup] target directory not found: %s\n' "$TARGET_DIR"
        return
    fi

    find "$TARGET_DIR" -mindepth 1 -type f -mtime +"$RETENTION_DAYS" -print -exec rm -f {} +
    find "$TARGET_DIR" -mindepth 1 -depth -type d -empty -print -exec rmdir {} \; || true

    if [ "$MAX_SIZE_MB" -eq 0 ]; then
        return
    fi

    current_mb=$(du -sm "$TARGET_DIR" 2>/dev/null | awk '{print $1}')
    while [ -n "$current_mb" ] && [ "$current_mb" -gt "$MAX_SIZE_MB" ]; do
        oldest_file=$(
            find "$TARGET_DIR" -type f -exec stat -c '%Y %n' {} + 2>/dev/null \
                | sort -n \
                | sed -n '1s/^[0-9][0-9]* //p'
        )

        if [ -z "$oldest_file" ]; then
            break
        fi

        printf '[modsec-cleanup] deleting oldest file: %s\n' "$oldest_file"
        rm -f "$oldest_file"
        current_mb=$(du -sm "$TARGET_DIR" 2>/dev/null | awk '{print $1}')
    done

    find "$TARGET_DIR" -mindepth 1 -depth -type d -empty -exec rmdir {} \; || true
}

if [ "${1:-}" = "--once" ]; then
    cleanup_once
    exit 0
fi

printf '[modsec-cleanup] starting; retention=%s days; max_size_mb=%s; interval=%ss; target=%s\n' \
    "$RETENTION_DAYS" "$MAX_SIZE_MB" "$INTERVAL_SECONDS" "$TARGET_DIR"

while true; do
    cleanup_once
    sleep "$INTERVAL_SECONDS"
done

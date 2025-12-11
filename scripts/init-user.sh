#!/bin/sh
# init-user.sh - Securely handle PUID/PGID changes and drop privileges
# This script runs as root initially to modify UID/GID, then drops to non-root
set -eu

log() {
    echo "[init-user] $1"
}

# Security: Validate UID/GID values
# - Must be numeric
# - Must be in valid range (100-60000 to avoid system users)
# - Cannot be 0 (root)
validate_id() {
    local value="$1"
    local name="$2"
    
    # Check if numeric
    case "$value" in
        ''|*[!0-9]*)
            log "ERROR: $name must be a numeric value, got: '$value'"
            return 1
            ;;
    esac
    
    # Security: Prevent running as root (UID/GID 0)
    if [ "$value" -eq 0 ]; then
        log "ERROR: $name cannot be 0 (root). This container must run as non-root for security."
        return 1
    fi
    
    # Security: Prevent using system user IDs (typically < 100)
    # and unreasonably high IDs (> 60000)
    if [ "$value" -lt 100 ] || [ "$value" -gt 60000 ]; then
        log "WARNING: $name=$value is outside recommended range (100-60000)"
        log "         System user IDs (< 100) may cause security issues"
    fi
    
    return 0
}

# Fix ownership of critical directories
fix_permissions() {
    local uid="$1"
    local gid="$2"
    
    log "Fixing ownership for UID:$uid GID:$gid..."
    
    # Fix phpBB root directory
    if [ -d "${PHPBB_ROOT:-/opt/phpbb}" ]; then
        chown -R "$uid:$gid" "${PHPBB_ROOT:-/opt/phpbb}" 2>/dev/null || {
            log "WARNING: Could not change ownership of ${PHPBB_ROOT:-/opt/phpbb}"
        }
    fi
    
    # Fix nginx directories
    for dir in /var/lib/nginx /var/log/nginx /run/nginx; do
        if [ -d "$dir" ]; then
            chown -R "$uid:$gid" "$dir" 2>/dev/null || true
        fi
    done
    
    # Fix nginx pid file
    if [ -f /run/nginx.pid ]; then
        chown "$uid:$gid" /run/nginx.pid 2>/dev/null || true
    fi
    
    # Fix PHP log directory (uses PHP_VERSION from environment)
    local php_ver="${PHP_VERSION:-84}"
    php_ver=$(echo "$php_ver" | tr -d '.')
    if [ -d "/var/log/php${php_ver}" ]; then
        chown -R "$uid:$gid" "/var/log/php${php_ver}" 2>/dev/null || true
    fi
}

main() {
    local current_uid
    local current_gid
    local target_uid
    local target_gid
    local need_uid_change=0
    local need_gid_change=0
    
    # Get current phpbb user's UID/GID
    current_uid=$(id -u phpbb 2>/dev/null || echo "1000")
    current_gid=$(id -g phpbb 2>/dev/null || echo "1000")
    
    # Determine target UID/GID (use PUID/PGID if set, otherwise keep current)
    target_uid="${PUID:-$current_uid}"
    target_gid="${PGID:-$current_gid}"
    
    # Check if we're running as root (needed to change UID/GID)
    if [ "$(id -u)" = "0" ]; then
        log "Running initial setup as root..."
        
        # Process PGID first (group must exist before user modification)
        if [ -n "${PGID:-}" ]; then
            if ! validate_id "$PGID" "PGID"; then
                log "ERROR: Invalid PGID value. Exiting."
                exit 1
            fi
            
            if [ "$PGID" != "$current_gid" ]; then
                log "Changing phpbb group GID from $current_gid to $PGID"
                
                # Check if GID is already in use by another group
                existing_group=$(getent group "$PGID" 2>/dev/null | cut -d: -f1 || true)
                if [ -n "$existing_group" ] && [ "$existing_group" != "phpbb" ]; then
                    log "WARNING: GID $PGID is already used by group '$existing_group'"
                    log "         Modifying that group to use a different GID"
                    groupmod -g 65534 "$existing_group" 2>/dev/null || true
                fi
                
                groupmod -g "$PGID" phpbb || {
                    log "ERROR: Failed to change GID to $PGID"
                    exit 1
                }
                need_gid_change=1
            fi
        fi
        
        # Process PUID
        if [ -n "${PUID:-}" ]; then
            if ! validate_id "$PUID" "PUID"; then
                log "ERROR: Invalid PUID value. Exiting."
                exit 1
            fi
            
            if [ "$PUID" != "$current_uid" ]; then
                log "Changing phpbb user UID from $current_uid to $PUID"
                
                # Check if UID is already in use by another user
                existing_user=$(getent passwd "$PUID" 2>/dev/null | cut -d: -f1 || true)
                if [ -n "$existing_user" ] && [ "$existing_user" != "phpbb" ]; then
                    log "WARNING: UID $PUID is already used by user '$existing_user'"
                    log "         Modifying that user to use a different UID"
                    usermod -u 65534 "$existing_user" 2>/dev/null || true
                fi
                
                usermod -u "$PUID" phpbb || {
                    log "ERROR: Failed to change UID to $PUID"
                    exit 1
                }
                need_uid_change=1
            fi
        fi
        
        # Fix permissions if UID or GID changed, or on first run to ensure correct ownership
        # This handles cases where volumes are mounted with different ownership
        if [ $need_uid_change -eq 1 ] || [ $need_gid_change -eq 1 ]; then
            fix_permissions "$target_uid" "$target_gid"
        else
            # Even without UID/GID changes, fix permissions on mounted volumes
            # This ensures files created by host or previous runs have correct ownership
            log "Ensuring correct file ownership..."
            fix_permissions "$(id -u phpbb)" "$(id -g phpbb)"
        fi
        
        # Log the final user configuration
        log "Container will run as phpbb (UID=$(id -u phpbb), GID=$(id -g phpbb))"
        
        # Security: Drop privileges and execute the main entrypoint as phpbb user
        # su-exec is a minimal setuid binary that executes a command as another user
        # Unlike su, it doesn't create a new session or do any PAM processing
        log "Dropping privileges and starting application..."
        exec su-exec phpbb /opt/.docker/docker-entrypoint.sh "$@"
        
    else
        # Already running as non-root (e.g., in rootless Docker or with USER directive)
        log "Already running as non-root user (UID=$(id -u))"
        
        # Warn if PUID/PGID were set but we can't apply them
        if [ -n "${PUID:-}" ] || [ -n "${PGID:-}" ]; then
            log "WARNING: PUID/PGID environment variables are set but container is not running as root"
            log "         UID/GID changes require the container to start as root"
            log "         Current user: $(id)"
        fi
        
        # Execute the main entrypoint directly
        exec /opt/.docker/docker-entrypoint.sh "$@"
    fi
}

main "$@"

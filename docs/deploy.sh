#!/bin/bash
# =============================================================================
# deploy.sh — Docker image deploy with content-based change detection
# =============================================================================
# Pulls each image and compares the image ID before and after.
# Only restarts services when the image content actually changed.
#
# HOW TO ADD A NEW APP:
#   1. Add its image to IMAGE_SERVICE_MAP below:
#      ["ghcr.io/mis-projects-2025/your-image:latest"]="service-name"
#   2. If multiple services share the image, space-separate them:
#      ["ghcr.io/mis-projects-2025/your-image:latest"]="app app-worker"
# =============================================================================
# THIS EXISTS ON OTHER REDUNDANT SERVERS, YOU CHANGE THIS, YOU CHANGE THEM!
# =============================================================================

# -----------------------------------------------------------------------------
# IMAGE → SERVICE MAP
# -----------------------------------------------------------------------------
declare -A IMAGE_SERVICE_MAP=(
    ["ghcr.io/mis-projects-2025/lot-summary-directory:latest"]="lot-summary-directory lot-summary-directory-scheduler"
)

# -----------------------------------------------------------------------------
# CONFIG
# -----------------------------------------------------------------------------
COMPOSE_DIR="/var/www"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
LOG_DIR="$COMPOSE_DIR/logs/deploys"
MAIN_LOG="$LOG_DIR/deploy.log"

# -----------------------------------------------------------------------------
# SETUP
# -----------------------------------------------------------------------------
mkdir -p "$LOG_DIR"

# -----------------------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------------------
ts() {
    date '+%Y-%m-%d %H:%M:%S'
}

# Structured log levels
log_info()    { echo "[$(ts)]  INFO     $1" >> "$MAIN_LOG"; }
log_ok()      { echo "[$(ts)]  OK       $1" >> "$MAIN_LOG"; }
log_skip()    { echo "[$(ts)]  SKIP     $1" >> "$MAIN_LOG"; }
log_warn()    { echo "[$(ts)]  WARN     $1" >> "$MAIN_LOG"; }
log_error()   { echo "[$(ts)]  ERROR    $1" >> "$MAIN_LOG"; }
log_divider() { echo "------------------------------------------------------------" >> "$MAIN_LOG"; }
log_blank()   { echo "" >> "$MAIN_LOG"; }

log_service() {
    local service="$1"
    local msg="$2"
    local logfile="$LOG_DIR/${service}.log"
    touch "$logfile" 2>/dev/null || { log_warn "Cannot write to ${logfile}"; return; }
    echo "[$(ts)] $msg" >> "$logfile"
}

get_image_id() {
    local image="$1"
    docker inspect --format='{{.Id}}' "$image" 2>/dev/null || echo ""
}

copy_public_assets() {
    local service="$1"
    local container="www-${service}-1"
    local dest="/var/www/${service}/public"

    mkdir -p "$dest"
    if docker cp "${container}:/var/www/public/." "$dest/" 2>/dev/null; then
        chown -R 1000:33 "$dest"
        chmod -R 775 "$dest"
        log_ok       "  Assets synced    → ${service}"
        log_service "$service" "Assets synced."
    else
        log_warn     "  Assets sync failed (no /public?)  → ${service}"
        log_service "$service" "WARNING: Asset copy failed or no public folder."
    fi
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
log_blank
log_divider
log_info  "Deploy run started"
log_divider
log_blank

for IMAGE in "${!IMAGE_SERVICE_MAP[@]}"; do
    SERVICES="${IMAGE_SERVICE_MAP[$IMAGE]}"
    PRIMARY_SERVICE=$(echo "$SERVICES" | awk '{print $1}')
    SHORT_IMAGE="${IMAGE#ghcr.io/mis-projects-2025/}"

    log_info  "Checking  [$PRIMARY_SERVICE]  (${SHORT_IMAGE})"

    # Record image ID before pull
    ID_BEFORE=$(get_image_id "$IMAGE")

    # Pull latest
    PULL_OUTPUT=$(docker pull "$IMAGE" --quiet 2>&1)
    PULL_EXIT=$?

    if [ $PULL_EXIT -ne 0 ]; then
        log_error "Pull failed   → ${SHORT_IMAGE}"
        log_service "$PRIMARY_SERVICE" "ERROR: Pull failed. Output: $PULL_OUTPUT"
        log_blank
        continue
    fi

    # Record image ID after pull
    ID_AFTER=$(get_image_id "$IMAGE")

    CONTAINER_RUNNING=$(docker compose -f "$COMPOSE_FILE" ps --status running 2>/dev/null | grep -c "^$PRIMARY_SERVICE")

    if [ "$ID_BEFORE" = "$ID_AFTER" ] && [ "$CONTAINER_RUNNING" -gt 0 ]; then
        log_skip  "No changes        → ${SHORT_IMAGE}"
        log_blank
        continue
    fi

    log_info  "New image detected → restarting..."

    for SERVICE in $SERVICES; do
        # ...restart logic...

        if [ $? -eq 0 ]; then
            log_ok    "  Restarted        → ${SERVICE}"
            log_service "$SERVICE" "Restart successful."
            # Only sync assets for the primary web service
            if [ "$SERVICE" = "$PRIMARY_SERVICE" ]; then
                copy_public_assets "$SERVICE"
            fi
        else
            log_error "  Restart failed   → ${SERVICE}  (see ${SERVICE}.log)"
            log_service "$SERVICE" "ERROR: Restart failed."
        fi
    done

    log_blank
done

log_divider
log_info  "Reloading nginx..."
if docker exec www-nginx-1 nginx -s reload; then
    log_ok    "Nginx reloaded"
else
    log_error "Nginx reload failed"
fi
log_divider
log_info  "Deploy run finished"
log_divider
log_blank

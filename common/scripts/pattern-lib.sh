#!/usr/bin/env bash
# Pattern Library - Shared Functions for Validated Patterns  
# This library provides config-driven pattern management for both install and uninstall operations

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

# Global variables
declare -A PATTERN_CONFIG
declare -A PATTERN_METADATA
declare -A COMPONENTS
declare -A COMPONENT_STATUS
declare -a MONITOR_PIDS
MONITOR_DIR="/tmp/pattern-monitor-$$"
DEPLOYMENT_START_TIME=$(date +%s)
PATTERN_CONFIG_FILE="common/pattern-config.yaml"
PATTERN_METADATA_FILE="common/pattern-metadata.yaml"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Print functions with consistent formatting
print_header() {
    echo
    echo -e "${BOLD}${CYAN}========================================${NC}"
    echo -e "${BOLD}${CYAN} $1${NC}"
    echo -e "${BOLD}${CYAN}========================================${NC}"
    echo
}

print_success() {
    echo -e "${BOLD}${GREEN}✓ SUCCESS: $1${NC}"
}

print_error() {
    echo -e "${BOLD}${RED}✗ FAILED: $1${NC}"
}

print_warning() {
    echo -e "${BOLD}${YELLOW}⚠ WARNING: $1${NC}"
}

print_info() {
    echo -e "${BOLD}${CYAN}ℹ INFO: $1${NC}"
}

# Time formatting function
format_time() {
    local seconds=$1
    local minutes=$((seconds / 60))
    local remaining_seconds=$((seconds % 60))
    printf "%02d:%02d" $minutes $remaining_seconds
}

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

# Simple YAML parser for bash (handles our specific config structure)
parse_yaml_value() {
    local file="$1"
    local key="$2"
    local default="$3"
    
    if [ ! -f "$file" ]; then
        echo "$default"
        return
    fi
    
    # Handle nested keys like "pattern.name" or "display.column_widths.name"
    local value=""
    if [[ "$key" == *.* ]]; then
        # Multi-level key - use simpler approach for now
        # For display.column_widths.name, look for "name:" under "column_widths:" under "display:"
        case "$key" in
            "display.column_widths.name")
                value=$(sed -n '/^display:/,/^[a-z]/p' "$file" | sed -n '/column_widths:/,/^  [a-z]/p' | grep "name:" | sed 's/.*: *//' | tr -d ' ')
                ;;
            "display.column_widths.namespace")
                value=$(sed -n '/^display:/,/^[a-z]/p' "$file" | sed -n '/column_widths:/,/^  [a-z]/p' | grep "namespace:" | sed 's/.*: *//' | tr -d ' ')
                ;;
            "display.column_widths.version")
                value=$(sed -n '/^display:/,/^[a-z]/p' "$file" | sed -n '/column_widths:/,/^  [a-z]/p' | grep "version:" | sed 's/.*: *//' | tr -d ' ')
                ;;
            "pattern.name"|"pattern.display_name")
                local field=$(echo "$key" | cut -d'.' -f2)
                value=$(sed -n '/^pattern:/,/^[a-z]/p' "$file" | grep "$field:" | sed 's/.*: *//' | sed 's/^"//' | sed 's/"$//')
                ;;
            *)
                # For other nested keys, check if it's a category key
                if [[ "$key" == categories.*.title ]]; then
                    # Extract category name from key like "categories.infrastructure.title"
                    local category=$(echo "$key" | cut -d'.' -f2)
                    value=$(sed -n "/^  $category:/,/^  [a-z]/p" "$file" | grep "^    title:" | sed 's/.*: *//' | sed 's/^"//' | sed 's/"$//')
                elif [[ "$key" == categories.*.version_column_title ]]; then
                    # Extract category name from key like "categories.infrastructure.version_column_title"
                    local category=$(echo "$key" | cut -d'.' -f2)
                    value=$(sed -n "/^  $category:/,/^  [a-z]/p" "$file" | grep "version_column_title:" | sed 's/.*: *//' | sed 's/^"//' | sed 's/"$//')
                else
                    # For other nested keys, use a simple grep approach
                    local last_part=$(echo "$key" | sed 's/.*\.//')
                    value=$(grep "$last_part:" "$file" | head -1 | sed 's/.*: *//' | sed 's/^"//' | sed 's/"$//')
                fi
                ;;
        esac
    else
        # Single-level key
        value=$(grep "^$key:" "$file" 2>/dev/null | head -1 | sed 's/.*: *//' | sed 's/^"//' | sed 's/"$//')
    fi
    
    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# Load pattern configuration from YAML files
load_pattern_config() {
    print_info "Loading pattern configuration..."
    
    if [ ! -f "$PATTERN_CONFIG_FILE" ]; then
        print_error "Pattern config file not found: $PATTERN_CONFIG_FILE"
        return 1
    fi
    
    if [ ! -f "$PATTERN_METADATA_FILE" ]; then
        print_error "Pattern metadata file not found: $PATTERN_METADATA_FILE"
        return 1
    fi
    
    # Load basic pattern info
    PATTERN_CONFIG[name]=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "pattern.name" "unknown")
    PATTERN_CONFIG[display_name]=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "pattern.display_name" "Unknown Pattern")
    
    # Load display settings
    PATTERN_CONFIG[col_width_name]=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "display.column_widths.name" "50")
    PATTERN_CONFIG[col_width_namespace]=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "display.column_widths.namespace" "40")
    PATTERN_CONFIG[col_width_version]=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "display.column_widths.version" "40")
    
    # Load monitoring timeouts
    PATTERN_CONFIG[timeout_subscription_appear]=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "monitoring.timeouts.subscription_appear" "300")
    PATTERN_CONFIG[timeout_subscription_install]=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "monitoring.timeouts.subscription_install" "600")
    PATTERN_CONFIG[timeout_argocd_appear]=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "monitoring.timeouts.argocd_appear" "180")
    PATTERN_CONFIG[timeout_argocd_sync]=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "monitoring.timeouts.argocd_sync" "900")
    
    # Load metadata
    PATTERN_METADATA[description]=$(parse_yaml_value "$PATTERN_METADATA_FILE" "pattern.description" "")
    
    print_success "Pattern configuration loaded: ${PATTERN_CONFIG[display_name]}"
    return 0
}

# Parse components from config file
load_components() {
    print_info "Loading component definitions..."
    
    # Parse components from each category (NO HARDCODING!)
    # Extract category names dynamically from config
    local categories=()
    local found_categories=$(sed -n '/^categories:/,/^# /p' "$PATTERN_CONFIG_FILE" 2>/dev/null | grep "^  [a-z]" | sed 's/:.*$//' | sed 's/^  //')
    
    # Convert to array
    while IFS= read -r category; do
        if [ -n "$category" ]; then
            categories+=("$category")
        fi
    done <<< "$found_categories"
    
    for category in "${categories[@]}"; do
        # Extract component IDs for this category
        local comp_ids=$(sed -n "/^  $category:/,/^  [a-z]/p" "$PATTERN_CONFIG_FILE" 2>/dev/null | grep "id:" | awk '{print $3}' | tr -d '"')
        
        for comp_id in $comp_ids; do
            if [ -n "$comp_id" ]; then
                COMPONENTS["$comp_id"]="$category"
                load_component_details "$comp_id" "$category"
            fi
        done
    done
    
    print_success "Loaded ${#COMPONENTS[@]} component definitions"
    return 0
}

# Load individual component details
load_component_details() {
    local comp_id="$1"
    local category="$2"
    
    # Extract component details from YAML (simplified parsing)
    local comp_section=$(sed -n "/id: \"$comp_id\"/,/^      - id:/p" "$PATTERN_CONFIG_FILE" 2>/dev/null)
    
    # Parse key fields
    COMPONENTS["${comp_id}_name"]=$(echo "$comp_section" | grep "name:" | head -1 | sed 's/.*name: *//' | tr -d '"')
    COMPONENTS["${comp_id}_namespace"]=$(echo "$comp_section" | grep "namespace:" | head -1 | sed 's/.*namespace: *//' | tr -d '"')
    COMPONENTS["${comp_id}_monitor_type"]=$(echo "$comp_section" | grep "monitor_type:" | head -1 | sed 's/.*monitor_type: *//' | tr -d '"')
    COMPONENTS["${comp_id}_subscription_name"]=$(echo "$comp_section" | grep "subscription_name:" | head -1 | sed 's/.*subscription_name: *//' | tr -d '"')
    COMPONENTS["${comp_id}_argocd_app_name"]=$(echo "$comp_section" | grep "argocd_app_name:" | head -1 | sed 's/.*argocd_app_name: *//' | tr -d '"')
    COMPONENTS["${comp_id}_version_type"]=$(echo "$comp_section" | grep "type:" | head -1 | sed 's/.*type: *//' | tr -d '"')
    COMPONENTS["${comp_id}_version_key"]=$(echo "$comp_section" | grep "key:" | head -1 | sed 's/.*key: *//' | tr -d '"')
    COMPONENTS["${comp_id}_version_fallback"]=$(echo "$comp_section" | grep "fallback:" | head -1 | sed 's/.*fallback: *//' | tr -d '"')
    COMPONENTS["${comp_id}_chart_prefix"]=$(echo "$comp_section" | grep "chart_prefix:" | head -1 | sed 's/.*chart_prefix: *//' | tr -d '"')
}

# =============================================================================
# VERSION DISCOVERY
# =============================================================================

# Get version information for a component
get_component_version() {
    local comp_id="$1"
    local version_type="${COMPONENTS[${comp_id}_version_type]}"
    local version_key="${COMPONENTS[${comp_id}_version_key]}"
    local fallback="${COMPONENTS[${comp_id}_version_fallback]:-unknown}"
    local chart_prefix="${COMPONENTS[${comp_id}_chart_prefix]}"
    
    case "$version_type" in
        "values-global")
            get_values_global_version "$version_key" "$fallback"
            ;;
        "make-show")
            get_make_show_version "$version_key" "$fallback"
            ;;
        "values-hub")
            if [[ "$version_key" == *.chartVersion ]]; then
                local app_name=$(echo "$version_key" | cut -d'.' -f1)
                get_chart_version "$app_name" "$chart_prefix"
            else
                get_values_hub_version "$version_key" "$fallback"
            fi
            ;;
        *)
            echo "$fallback"
            ;;
    esac
}

# Get version from values-global.yaml
get_values_global_version() {
    local key="$1"
    local fallback="$2"
    local add_git_info="${3:-false}"
    
    local version=$(grep "$key:" values-global.yaml 2>/dev/null | awk '{print $2}' | tr -d '"')
    
    if [ -z "$version" ]; then
        version="not found in values-global.yaml"
    fi
    
    # Add git info if requested (for pattern CR)
    if [ "$add_git_info" = "true" ] && git rev-parse --short HEAD >/dev/null 2>&1; then
        local branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        local commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        version="$version ($branch@$commit)"
    fi
    
    echo "$version"
}

# Get version from make show command
get_make_show_version() {
    local key="$1"
    local fallback="$2"
    
    local show_output=$(./pattern.sh make show 2>&1)
    local make_exit_code=$?
    
    if [ $make_exit_code -ne 0 ] || [ -z "$show_output" ]; then
        echo "$fallback"
        return
    fi
    
    local version=$(echo "$show_output" | grep "$key:" | awk '{print $2}')
    if [ -n "$version" ]; then
        echo "$version"
    else
        echo "not found in 'make show'"
    fi
}

# Get version from values-hub.yaml
get_values_hub_version() {
    local key="$1"
    local fallback="$2"
    
    local version=$(grep -A 5 "^    $(echo "$key" | cut -d'.' -f1):" values-hub.yaml 2>/dev/null | grep "$(echo "$key" | cut -d'.' -f2):" | awk '{print $2}')
    if [ -n "$version" ]; then
        echo "$version"
    else
        echo "$fallback"
    fi
}

# Get chart version (supports both remote and local charts)
get_chart_version() {
    local app_name="$1"
    local chart_prefix="$2"
    
    # Extract chartVersion from values-hub.yaml
    local version=$(grep -A 6 "^    $app_name:" values-hub.yaml 2>/dev/null | grep "chartVersion:" | awk '{print $2}' | tr -d '"')
    
    if [ -n "$version" ]; then
        if [ -n "$chart_prefix" ]; then
            echo "$chart_prefix $version"
        else
            echo "$version"
        fi
        return
    fi
    
    # Check if it's a local chart
    local chart_path=$(grep -A 6 "^    $app_name:" values-hub.yaml 2>/dev/null | grep "path:" | awk '{print $2}')
    if [ -n "$chart_path" ]; then
        local local_version=$(grep "^version:" "$chart_path/Chart.yaml" 2>/dev/null | awk '{print $2}')
        if [ -n "$local_version" ]; then
            if [ -n "$chart_prefix" ]; then
                echo "$chart_prefix $local_version"
            else
                echo "$local_version"
            fi
            return
        fi
    fi
    
    echo "unknown"
}

# =============================================================================
# COMPONENT LISTING AND TABLES
# =============================================================================

# Print component tables for install/uninstall preview
print_component_tables() {
    local operation="${1:-install}"
    
    # Get pattern display name
    local pattern_display_name="${PATTERN_CONFIG[display_name]}"
    local title_template="$pattern_display_name - ASYNC INSTALLATION PLAN"
    if [ "$operation" = "uninstall" ]; then
        title_template="VERBOSE PATTERN UNINSTALL v3.8 (COMPLETE-ARGOCD-AWARE) - INITIAL STATE CHECK"
    fi
    
    print_header "$title_template"
    
    if [ "$operation" = "install" ]; then
        print_info "The following components will be monitored in parallel:"
        echo
    fi
    
    # Track printed categories to avoid duplicates
    local -a PRINTED_CATEGORIES=()
    
    # Print each category (dynamically from config)
    for comp_id in "${!COMPONENTS[@]}"; do
        if [[ "$comp_id" != *_* ]]; then
            local category="${COMPONENTS[$comp_id]}"
            if [ -n "$category" ]; then
                # Track unique categories
                local found=false
                for existing_cat in "${PRINTED_CATEGORIES[@]:-}"; do
                    if [ "$existing_cat" = "$category" ]; then
                        found=true
                        break
                    fi
                done
                if [ "$found" = false ]; then
                    PRINTED_CATEGORIES+=("$category")
                    print_category_table "$category"
                fi
            fi
        fi
    done
    
    if [ "$operation" = "install" ]; then
        print_info "DEPLOYMENT FLOW:"
        echo "  Pattern CR + Vault → Secrets Loading → Patterns Operator → GitOps + Direct Operators → ArgoCD Applications → Component Deployment"
        echo
    fi
}

# Print a single category table
print_category_table() {
    local category="$1"
    local col_width_name="${PATTERN_CONFIG[col_width_name]}"
    local col_width_namespace="${PATTERN_CONFIG[col_width_namespace]}"
    local col_width_version="${PATTERN_CONFIG[col_width_version]}"
    
    # Get category title from config (NO HARDCODING!)
    local category_title=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "categories.${category}.title" "$category")
    if [ "$category_title" = "$category" ]; then
        # Fallback if not found in config
        category_title="$(echo "$category" | tr '[:lower:]' '[:upper:]')"
    fi
    
    print_info "$category_title:"
    
    # Print table header (get from config)
    local version_header=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "categories.${category}.version_column_title" "VERSION")
    
    printf "%-${col_width_name}s | %-${col_width_namespace}s | %s\n" "NAME" "NAMESPACE" "$version_header"
    printf "%-${col_width_name}s | %-${col_width_namespace}s | %s\n" \
        "$(printf '%*s' "$col_width_name" '' | tr ' ' '-')" \
        "$(printf '%*s' "$col_width_namespace" '' | tr ' ' '-')" \
        "$(printf '%*s' "$col_width_version" '' | tr ' ' '-')"
    
    # Print components for this category
    for comp_id in "${!COMPONENTS[@]}"; do
        if [[ "$comp_id" != *_* ]] && [ "${COMPONENTS[$comp_id]}" = "$category" ]; then
            local comp_name="${COMPONENTS[${comp_id}_name]}"
            local comp_namespace="${COMPONENTS[${comp_id}_namespace]}"
            local comp_version=$(get_component_version "$comp_id")
            
            printf "%-${col_width_name}s | %-${col_width_namespace}s | %s\n" "$comp_name" "$comp_namespace" "$comp_version"
        fi
    done
    
    echo
}

# =============================================================================
# STATUS TRACKING
# =============================================================================

# Initialize monitoring directory
init_monitoring() {
    mkdir -p "$MONITOR_DIR"
    
    # Cleanup function
    cleanup_monitoring() {
        print_info "Cleaning up monitoring processes..."
        for pid in "${MONITOR_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        rm -rf "$MONITOR_DIR" 2>/dev/null || true
    }
    trap cleanup_monitoring EXIT
}

# Update component status
update_status() {
    local component="$1"
    local status="$2"
    local details="$3"
    
    local current_status=$(get_status "$component" | cut -d'|' -f1)
    local timestamp=$(date +%s)
    
    if [ "$current_status" != "$status" ]; then
        echo "$status|$details|$timestamp" > "$MONITOR_DIR/$component.status"
    else
        local original_timestamp=$(get_status "$component" | cut -d'|' -f3)
        echo "$status|$details|$original_timestamp" > "$MONITOR_DIR/$component.status"
    fi
}

# Get component status
get_status() {
    local component="$1"
    if [ -f "$MONITOR_DIR/$component.status" ]; then
        cat "$MONITOR_DIR/$component.status"
    else
        echo "PENDING||$(date +%s)"
    fi
}

# =============================================================================
# COMPONENT MONITORING
# =============================================================================

# Start monitor for a component based on its type
start_component_monitor() {
    local comp_id="$1"
    local monitor_type="${COMPONENTS[${comp_id}_monitor_type]}"
    
    case "$monitor_type" in
        "subscription")
            start_subscription_monitor "$comp_id" &
            MONITOR_PIDS+=($!)
            ;;
        "argocd")
            start_argocd_monitor "$comp_id" &
            MONITOR_PIDS+=($!)
            ;;
        "pattern-cr")
            # Pattern CR monitoring is handled in main deploy function
            ;;
        *)
            print_warning "Unknown monitor type: $monitor_type for component: $comp_id"
            ;;
    esac
}

# Monitor subscription installation
start_subscription_monitor() {
    local comp_id="$1"
    local subscription_name="${COMPONENTS[${comp_id}_subscription_name]}"
    local namespace="${COMPONENTS[${comp_id}_namespace]}"
    local timeout_appear="${PATTERN_CONFIG[timeout_subscription_appear]}"
    local timeout_install="${PATTERN_CONFIG[timeout_subscription_install]}"
    
    update_status "$comp_id" "WAITING" "Waiting for subscription creation"
    
    # Wait for subscription to be created
    local elapsed=0
    while [ $elapsed -lt $timeout_appear ]; do
        if oc get subscription "$subscription_name" -n "$namespace" >/dev/null 2>&1; then
            update_status "$comp_id" "INSTALLING" "Subscription found, installing operator"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    if [ $elapsed -ge $timeout_appear ]; then
        update_status "$comp_id" "FAILED" "Subscription not created after $timeout_appear seconds"
        return 1
    fi
    
    # Monitor installation
    elapsed=0
    while [ $elapsed -lt $timeout_install ]; do
        local install_state=$(oc get subscription "$subscription_name" -n "$namespace" -o jsonpath='{.status.state}' 2>/dev/null)
        if [[ "$install_state" == "AtLatestKnown" ]]; then
            update_status "$comp_id" "SUCCESS" "Operator installed successfully"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    update_status "$comp_id" "FAILED" "Installation timeout after $timeout_install seconds"
    return 1
}

# Monitor ArgoCD application
start_argocd_monitor() {
    local comp_id="$1"
    local app_name="${COMPONENTS[${comp_id}_argocd_app_name]}"
    local timeout_appear="${PATTERN_CONFIG[timeout_argocd_appear]}"
    local timeout_sync="${PATTERN_CONFIG[timeout_argocd_sync]}"
    
    update_status "$comp_id" "WAITING" "Waiting for ArgoCD application"
    
    # Wait for application to appear
    local elapsed=0
    local app_namespace=""
    
    while [ $elapsed -lt $timeout_appear ]; do
        local app_info=$(oc get applications.argoproj.io -A --no-headers 2>/dev/null | grep "^[^[:space:]]*[[:space:]]*$app_name[[:space:]]" | head -1)
        if [ -n "$app_info" ]; then
            app_namespace=$(echo "$app_info" | awk '{print $1}')
            update_status "$comp_id" "SYNCING" "Application found in $app_namespace, monitoring sync"
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    if [ -z "$app_namespace" ]; then
        update_status "$comp_id" "FAILED" "Application not found after $timeout_appear seconds"
        return 1
    fi
    
    # Monitor sync and health
    elapsed=0
    while [ $elapsed -lt $timeout_sync ]; do
        local sync_status=$(oc get application.argoproj.io "$app_name" -n "$app_namespace" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        local health_status=$(oc get application.argoproj.io "$app_name" -n "$app_namespace" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        
        if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]]; then
            update_status "$comp_id" "SUCCESS" "Synced and Healthy"
            return 0
        elif [[ "$sync_status" == "OutOfSync" ]]; then
            update_status "$comp_id" "SYNCING" "Sync: $sync_status, Health: $health_status"
        else
            update_status "$comp_id" "PROGRESSING" "Sync: $sync_status, Health: $health_status"
        fi
        
        sleep 15
        elapsed=$((elapsed + 15))
    done
    
    update_status "$comp_id" "FAILED" "Timeout - Sync: $sync_status, Health: $health_status"
    return 1
}

# =============================================================================
# DASHBOARD DISPLAY
# =============================================================================

# Show live monitoring dashboard
show_live_dashboard() {
    local max_wait="${PATTERN_CONFIG[max_wait]:-1800}"
    local start_time=$(date +%s)
    
    print_header "LIVE MONITORING DASHBOARD"
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $max_wait ]; then
            print_warning "Maximum monitoring time reached (30 minutes)"
            break
        fi
        
        # Clear screen and show header
        clear
        print_header "LIVE MONITORING DASHBOARD"
        echo "Elapsed: $(format_time $elapsed) | Last Update: $(date '+%H:%M:%S')"
        echo
        
        local all_done=true
        local success_count=0
        local failed_count=0
        
        # Display each category (dynamically from config)
        local -a displayed_categories=()
        for comp_id in "${!COMPONENTS[@]}"; do
            if [[ "$comp_id" != *_* ]]; then
                local category="${COMPONENTS[$comp_id]}"
                if [ -n "$category" ]; then
                    # Check if category already displayed
                    local found=false
                    for displayed_cat in "${displayed_categories[@]}"; do
                        if [ "$displayed_cat" = "$category" ]; then
                            found=true
                            break
                        fi
                    done
                    if [ "$found" = false ]; then
                        displayed_categories+=("$category")
                        display_category_status "$category" current_time success_count failed_count all_done
                    fi
                fi
            fi
        done
        
        echo
        local total_components=$(count_total_components)
        echo "Progress: Success=$success_count, Failed=$failed_count, Active=$((total_components - success_count - failed_count))"
        
        if [ "$all_done" = true ]; then
            print_success "All components completed!"
            break
        fi
        
        sleep 15
    done
}

# Display status for a category in the dashboard
display_category_status() {
    local category="$1"
    local current_time_var="$2"
    local success_count_var="$3"
    local failed_count_var="$4"
    local all_done_var="$5"
    
    local current_time=${!current_time_var}
    local success_count=${!success_count_var}
    local failed_count=${!failed_count_var}
    local all_done=${!all_done_var}
    
    # Get category title from config (NO HARDCODING!)
    local category_title=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "categories.${category}.title" "$category")
    if [ "$category_title" = "$category" ]; then
        # Fallback if not found in config - use shortened version for dashboard
        case "$category" in
            "infrastructure") category_title="INFRASTRUCTURE" ;;
            "operators") category_title="OPERATORS" ;;
            "applications") category_title="APPLICATIONS" ;;
            *) category_title="$(echo "$category" | tr '[:lower:]' '[:upper:]')" ;;
        esac
    fi
    
    echo -e "${BOLD}${CYAN}$category_title${NC}"
    printf "%-50s %-12s %-8s %s\n" "COMPONENT" "STATUS" "IN STATUS" "DETAILS"
    echo "─────────────────────────────────────────────────────────────────────────────────────────────"
    
    # Display components for this category
    for comp_id in "${!COMPONENTS[@]}"; do
        if [[ "$comp_id" != *_* ]] && [ "${COMPONENTS[$comp_id]}" = "$category" ]; then
            local comp_name="${COMPONENTS[${comp_id}_name]}"
            local status_line=$(get_status "$comp_id")
            IFS='|' read -r status details timestamp <<< "$status_line"
            
            local duration=""
            if [ -n "$timestamp" ]; then
                duration="$(format_time $((current_time - timestamp)))"
            fi
            
            case "$status" in
                "SUCCESS")
                    printf "%-50s ${GREEN}%-12s${NC} %-8s %s\n" "$comp_name" "✓ SUCCESS" "$duration" "$details"
                    success_count=$((success_count + 1))
                    ;;
                "FAILED")
                    printf "%-50s ${RED}%-12s${NC} %-8s %s\n" "$comp_name" "✗ FAILED" "$duration" "$details"
                    failed_count=$((failed_count + 1))
                    ;;
                "DEPLOYING"|"INSTALLING"|"SYNCING"|"PROGRESSING")
                    printf "%-50s ${YELLOW}%-12s${NC} %-8s %s\n" "$comp_name" "⚠ $status" "$duration" "$details"
                    all_done=false
                    ;;
                *)
                    printf "%-50s ${CYAN}%-12s${NC} %-8s %s\n" "$comp_name" "○ $status" "$duration" "$details"
                    all_done=false
                    ;;
            esac
        fi
    done
    
    echo
    
    # Update variables by reference (bash doesn't support this directly, so we use global variables)
    eval "$success_count_var=$success_count"
    eval "$failed_count_var=$failed_count"
    eval "$all_done_var=$all_done"
}

# Count total components
count_total_components() {
    local count=0
    for comp_id in "${!COMPONENTS[@]}"; do
        if [[ "$comp_id" != *_* ]]; then
            count=$((count + 1))
        fi
    done
    echo $count
}

# =============================================================================
# INSTALLATION FUNCTIONS
# =============================================================================

# Deploy core pattern using helm
deploy_core_pattern() {
    local name="$1"
    local chart="$2"
    shift 2
    local helm_opts="$*"
    
    print_header "DEPLOYING CORE PATTERN INFRASTRUCTURE + VAULT"
    print_info "Installing pattern base infrastructure and HashiCorp Vault..."
    
    update_status "pattern-cr" "DEPLOYING" "Installing helm chart"
    
    local runs="${PATTERN_CONFIG[helm_deploy_retries]:-10}"
    local wait="${PATTERN_CONFIG[helm_wait_seconds]:-15}"
    
    # Deploy Pattern CR first
    for i in $(seq 1 ${runs}); do
        exec 3>&1 4>&2
        OUT=$( { helm template --include-crds --name-template $name $chart $helm_opts 2>&4 | oc apply -f- 2>&4 1>&3; } 4>&1 3>&1)
        ret=$?
        exec 3>&- 4>&-
        if [ ${ret} -eq 0 ]; then
            break;
        else
            echo -n "."
            sleep "${wait}"
        fi
    done

    if [ ${i} -eq ${runs} ]; then
        update_status "pattern-cr" "FAILED" "Deployment failed after ${runs} attempts: $OUT"
        print_error "Core pattern deployment failed"
        return 1
    fi
    
    update_status "pattern-cr" "SUCCESS" "Pattern CR deployed successfully"
    print_success "Pattern CR deployed - now deploying Vault..."
    
    # Deploy Vault immediately after Pattern CR
    update_status "vault-app" "DEPLOYING" "Installing HashiCorp Vault"
    
    # Get Vault chart version from config
    local vault_version=$(parse_yaml_value "values-hub.yaml" "clusterGroup.applications.vault.chartVersion" "0.1.*")
    
    for i in $(seq 1 ${runs}); do
        exec 3>&1 4>&2
        # Deploy Vault using OCI chart reference
        OUT=$( { helm template vault oci://quay.io/validatedpatterns/hashicorp-vault --version "$vault_version" \
            --namespace vault --create-namespace 2>&4 | oc apply -f- 2>&4 1>&3; } 4>&1 3>&1)
        ret=$?
        exec 3>&- 4>&-
        if [ ${ret} -eq 0 ]; then
            break;
        else
            echo -n "."
            sleep "${wait}"
        fi
    done

    if [ ${i} -eq ${runs} ]; then
        update_status "vault-app" "FAILED" "Vault deployment failed after ${runs} attempts: $OUT"
        print_error "Vault deployment failed"
        return 1
    fi
    
    update_status "vault-app" "SUCCESS" "Vault deployed successfully"
    print_success "Core infrastructure + Vault deployed - waiting for Vault to be ready..."
    
    # Wait for Vault to be ready before proceeding
    wait_for_vault_ready
    
    return 0
}

# Wait for Vault to be ready
wait_for_vault_ready() {
    print_info "Waiting for Vault to be ready..."
    local timeout=300  # 5 minutes
    local elapsed=0
    local check_interval=10
    
    while [ $elapsed -lt $timeout ]; do
        # Check if Vault pod is running
        local vault_ready=$(oc get pods -n vault -l app.kubernetes.io/name=vault --no-headers 2>/dev/null | grep "Running" | wc -l | tr -d ' ')
        
        if [ "$vault_ready" -gt 0 ]; then
            # Check if Vault API is responding (simplified check)
            local vault_status=$(oc exec -n vault deployment/vault -- vault status -format=json 2>/dev/null | jq -r '.initialized' 2>/dev/null || echo "false")
            
            if [ "$vault_status" = "true" ] || [ "$vault_status" = "false" ]; then
                # Vault API is responding (initialized or not, doesn't matter for secret loading)
                print_success "Vault is ready and API is responding"
                return 0
            fi
        fi
        
        echo -n "."
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done
    
    print_warning "Vault readiness check timed out after 5 minutes, proceeding anyway..."
    print_info "Secrets loading will retry if Vault is not fully ready"
    return 0  # Don't fail the deployment, just warn
}

# Load secrets before application monitoring
load_secrets() {
    local pattern_name="$1"
    
    print_header "LOADING SECRETS (BEFORE APPLICATION MONITORING)"
    print_info "Loading secrets before ArgoCD applications start syncing..."
    
    update_status "secrets" "LOADING" "Processing secrets"
    
    if common/scripts/process-secrets.sh "$pattern_name"; then
        update_status "secrets" "SUCCESS" "Secrets loaded successfully"
        print_success "Secrets loaded successfully"
    else
        update_status "secrets" "FAILED" "Secrets loading failed"
        print_error "Secrets loading failed"
    fi
}

# Start all component monitors
start_all_monitors() {
    print_header "STARTING ASYNC COMPONENT MONITORING"
    
    local monitor_count=0
    
    # Start monitors for all components
    for comp_id in "${!COMPONENTS[@]}"; do
        if [[ "$comp_id" != *_* ]]; then
            local comp_name="${COMPONENTS[${comp_id}_name]}"
            local monitor_type="${COMPONENTS[${comp_id}_monitor_type]}"
            
            if [ "$monitor_type" != "pattern-cr" ]; then
                print_info "Starting $monitor_type monitor for: $comp_name"
                start_component_monitor "$comp_id"
                monitor_count=$((monitor_count + 1))
            fi
        fi
    done
    
    print_success "All monitors started! Monitoring $monitor_count components in parallel"
}

# Print final installation summary
print_final_summary() {
    print_header "ASYNC INSTALLATION SUMMARY"
    
    local total_time=$(($(date +%s) - DEPLOYMENT_START_TIME))
    echo "Total installation time: $(format_time $total_time)"
    echo
    
    local success_count=0
    local failed_count=0
    
    print_info "Final Component Status:"
    echo
    
    # Check all components plus secrets
    for comp_id in "${!COMPONENTS[@]}"; do
        if [[ "$comp_id" != *_* ]]; then
            local comp_name="${COMPONENTS[${comp_id}_name]}"
            local status_line=$(get_status "$comp_id")
            IFS='|' read -r status details timestamp <<< "$status_line"
            
            if [[ "$status" == "SUCCESS" ]]; then
                print_success "$comp_name"
                success_count=$((success_count + 1))
            else
                print_error "$comp_name - $details"
                failed_count=$((failed_count + 1))
            fi
        fi
    done
    
    # Check secrets status
    local secrets_status_line=$(get_status "secrets")
    IFS='|' read -r secrets_status secrets_details secrets_timestamp <<< "$secrets_status_line"
    if [[ "$secrets_status" == "SUCCESS" ]]; then
        print_success "Secrets Loading"
        success_count=$((success_count + 1))
    else
        print_error "Secrets Loading - $secrets_details"
        failed_count=$((failed_count + 1))
    fi
    
    echo
    print_info "Statistics:"
    echo "  Total components: $((success_count + failed_count))"
    echo "  Successful: $success_count"
    echo "  Failed: $failed_count"
    
    if [ $failed_count -eq 0 ]; then
        echo
        print_success "🎉 COMPLETE ASYNC INSTALLATION SUCCESS! 🎉"
        print_info "All components deployed successfully using parallel monitoring!"
        return 0
    else
        echo
        print_warning "Some components failed. Check ArgoCD console for details."
        print_info "You can check overall status with: make argo-healthcheck"
        return 1
    fi
}

# =============================================================================
# UNINSTALL FUNCTIONS
# =============================================================================

# Check initial state for uninstall
check_uninstall_state() {
    local pattern_name="$1"
    
    print_header "INITIAL STATE CHECK"
    print_info "Scanning for ALL pattern resources (not just CRs)..."
    
    local pattern_count=$(oc get pattern "$pattern_name" -n openshift-operators --no-headers 2>/dev/null | wc -l | tr -d ' ')
    local apps_count=$(oc get applications.argoproj.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    # Count namespaces using config
    local namespaces_count=0
    local cleanup_pattern=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "uninstall.cleanup_patterns.namespaces" "(vault|keycloak|cert-manager|zero-trust|external-secrets)")
    namespaces_count=$(oc get ns 2>/dev/null | grep -E "$cleanup_pattern" | wc -l | tr -d ' ')
    
    # Count pods in pattern namespaces
    local pods_count=0
    local namespace_list=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "uninstall.deletion_order" "")
    
    # Extract namespaces from component definitions (NO HARDCODING!)
    for comp_id in "${!COMPONENTS[@]}"; do
                 if [[ "$comp_id" != *_* ]]; then
             local ns="${COMPONENTS[${comp_id}_namespace]}"
             if [ -n "$ns" ]; then
                 local ns_pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
                 pods_count=$((pods_count + ns_pods))
             fi
         fi
    done
    
    # Also check pattern hub namespace
    local hub_ns="${pattern_name}-hub"
    local hub_pods=$(oc get pods -n "$hub_ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    pods_count=$((pods_count + hub_pods))
    
    local subscriptions_pattern=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "uninstall.cleanup_patterns.subscriptions" "(cert-manager|rhbk|compliance|zero-trust)")
    local subscriptions_count=$(oc get subscriptions -A --no-headers 2>/dev/null | grep -E "$subscriptions_pattern" | wc -l | tr -d ' ')
    
    local csvs_pattern=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "uninstall.cleanup_patterns.csvs" "(cert-manager|keycloak|rhbk|compliance|zero-trust)")
    local csvs_count=$(oc get csv -A --no-headers 2>/dev/null | grep -E "$csvs_pattern" | wc -l | tr -d ' ')
    
    echo "Current Pattern Footprint:"
    echo "  Pattern CR '$pattern_name': $pattern_count"
    echo "  ArgoCD applications: $apps_count"
    echo "  Pattern namespaces: $namespaces_count"
    echo "  Running pods in pattern namespaces: $pods_count"
    echo "  Operator subscriptions: $subscriptions_count"
    echo "  Installed operators (CSVs): $csvs_count"
    
    local total_resources=$((pattern_count + apps_count + namespaces_count + pods_count + subscriptions_count + csvs_count))
    
    if [ $total_resources -eq 0 ]; then
        print_success "No pattern resources found - cluster is already clean!"
        return 1
    fi
    
    print_warning "Found $total_resources total pattern-related resources to clean up"
    return 0
}

# Ask for confirmation
ask_confirmation() {
    local operation="${1:-install}"
    local pattern_name="${2}"
    
    local header="COMPLETE PATTERN CLEANUP CONFIRMATION"
    local prompt="Do you want to proceed with async installation? (y/N): "
    
    if [ "$operation" = "uninstall" ]; then
        header="COMPLETE PATTERN CLEANUP CONFIRMATION"
        prompt="Do you want to proceed with COMPLETE uninstall? (y/N): "
        
        print_header "$header"
        print_info "Pattern: $pattern_name"
        print_warning "This will perform a COMPLETE cleanup including:"
        echo "  • ArgoCD applications (deleted in reverse installation order)"
        echo "  • ArgoCD/GitOps operator itself"
        echo "  • All operator installations (CSVs and subscriptions)"
        echo "  • All pattern namespaces and their contents"
        echo "  • All deployed workloads (pods, services, deployments, etc.)"
        echo "  • Pattern CR itself"
        echo
        print_warning "This uses reverse-order ArgoCD app deletion (mimicking manual ArgoCD UI deletion)!"
    fi
    
    echo
    echo -ne "${BOLD}${YELLOW}$prompt${NC}"
    read -r response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            return 0
            ;;
        *)
            echo "Operation cancelled by user."
            exit 0
            ;;
    esac
}

# =============================================================================
# LIBRARY INITIALIZATION
# =============================================================================

# Initialize the pattern library
init_pattern_lib() {
    # Load configuration first
    if ! load_pattern_config; then
        print_error "Failed to load pattern configuration"
        return 1
    fi
    
    # Load component definitions
    if ! load_components; then
        print_error "Failed to load component definitions"
        return 1
    fi
    
    # Initialize monitoring
    init_monitoring
    
    return 0
}

# Export key functions for use by other scripts
export -f print_header print_success print_error print_warning print_info
export -f format_time
export -f load_pattern_config load_components
export -f get_component_version
export -f print_component_tables
export -f update_status get_status
export -f start_component_monitor start_all_monitors
export -f show_live_dashboard print_final_summary
export -f deploy_core_pattern load_secrets
export -f check_uninstall_state ask_confirmation
export -f init_pattern_lib 
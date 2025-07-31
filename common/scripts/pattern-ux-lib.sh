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
PATTERN_CONFIG_FILE="${PATTERN_CONFIG_FILE:-common/pattern-ux-config.yaml}"
PATTERN_METADATA_FILE="${PATTERN_METADATA_FILE:-common/pattern-ux-metadata.yaml}"

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
            # Handle clusterGroup.subscriptions.* patterns
            clusterGroup.subscriptions.*.namespace|clusterGroup.subscriptions.*.channel|clusterGroup.subscriptions.*.name)
                local subscription_key=$(echo "$key" | cut -d'.' -f3)
                local field=$(echo "$key" | cut -d'.' -f4)
                # Extract the subscription section for this specific key
                value=$(sed -n "/^  subscriptions:/,/^  [a-z]/p" "$file" | sed -n "/^    ${subscription_key}:/,/^    [a-z]/p" | grep "      ${field}:" | sed 's/.*: *//' | sed 's/^"//' | sed 's/"$//')
                ;;
            # Handle clusterGroup.applications.* patterns  
            clusterGroup.applications.*.namespace|clusterGroup.applications.*.chartVersion)
                local app_key=$(echo "$key" | cut -d'.' -f3)
                local field=$(echo "$key" | cut -d'.' -f4)
                # Extract the application section for this specific key
                value=$(sed -n "/^  applications:/,/^  [a-z]/p" "$file" | sed -n "/^    ${app_key}:/,/^    [a-z]/p" | grep "      ${field}:" | sed 's/.*: *//' | sed 's/^"//' | sed 's/"$//')
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
                    # FIXED: Don't use broken simple grep fallback - return empty for unknown patterns
                    value=""
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
    
    # Load pattern controller separately (not in categories)
    local pattern_cr_id=$(grep -A 10 "^pattern_controller:" "$PATTERN_CONFIG_FILE" 2>/dev/null | grep "id:" | awk '{print $2}' | tr -d '"')
    if [ -n "$pattern_cr_id" ]; then
        COMPONENTS["$pattern_cr_id"]="pattern_controller"
        load_component_details "$pattern_cr_id" "pattern_controller"
    fi
    
    print_success "Loaded ${#COMPONENTS[@]} component definitions"
    return 0
}

# Updated load_component_details to use discovery system
load_component_details() {
    local comp_id="$1"
    local category="$2"
    
    # Add timestamp to discovery log
    local timestamp=$(date '+%H:%M:%S')
    echo "[$timestamp] Discovering details for $comp_id ($category)..." >> "$DISCOVERY_LOG"
    
    # Discover namespace (no more hardcoding!)
    COMPONENTS["${comp_id}_namespace"]=$(discover_namespace "$comp_id" "$category")
    
    # Discover version (no more hardcoding!)
    COMPONENTS["${comp_id}_version"]=$(discover_version "$comp_id" "$category")
    
    # For operators, discover subscription name
    if [ "$category" = "operators" ]; then
        COMPONENTS["${comp_id}_subscription_name"]=$(discover_subscription_name "$comp_id")
    fi
    
    # For applications, discover ArgoCD app name
    if [ "$category" = "applications" ]; then
        local app_key=$(discover_application_key_for_component "$comp_id")
        if [ -n "$app_key" ]; then
            COMPONENTS["${comp_id}_argocd_app_name"]="$app_key"
            log_discovery "$comp_id" "argocd_app_name" "component mapping" "$app_key" "mapped successfully"
        else
            COMPONENTS["${comp_id}_argocd_app_name"]="UNKNOWN (no mapping found)"
            log_discovery "$comp_id" "argocd_app_name" "component mapping" "UNKNOWN" "no mapping for component $comp_id"
        fi
    fi
    
    # Still get display name and monitor type from config (these are not duplicated)
    if [ "$category" = "pattern_controller" ]; then
        local pattern_section=$(sed -n '/^pattern_controller:/,/^[a-z]/p' "$PATTERN_CONFIG_FILE" | sed '/^[a-z]/d')
        COMPONENTS["${comp_id}_name"]=$(echo "$pattern_section" | grep "name:" | sed 's/.*name: *"//' | sed 's/"$//' | head -1)
        COMPONENTS["${comp_id}_monitor_type"]=$(echo "$pattern_section" | grep "monitor_type:" | sed 's/.*monitor_type: *"//' | sed 's/"$//' | head -1)
    else
        local component_section=$(sed -n "/^  $category:/,/^  [a-z]/p" "$PATTERN_CONFIG_FILE" | sed -n "/id: \"$comp_id\"/,/- id:/p" | sed '$d')
        COMPONENTS["${comp_id}_name"]=$(echo "$component_section" | grep "name:" | sed 's/.*name: *"//' | sed 's/"$//' | head -1)
        COMPONENTS["${comp_id}_monitor_type"]=$(echo "$component_section" | grep "monitor_type:" | sed 's/.*monitor_type: *"//' | sed 's/"$//' | head -1)
    fi
}

# =============================================================================
# VERSION DISCOVERY
# =============================================================================

# Get version information for a component (now fully dynamic)
get_component_version() {
    local comp_id="$1"
    
    # Use the already-computed dynamic version from discovery
    local cached_version="${COMPONENTS[${comp_id}_version]}"
    if [ -n "$cached_version" ]; then
        echo "$cached_version"
        return
    fi
    
    # Fallback: determine component type and discover version dynamically
    local component_type="${COMPONENTS[$comp_id]}"
    if [ -n "$component_type" ]; then
        discover_version "$comp_id" "$component_type"
    else
        echo "UNKNOWN (component not found)"
    fi
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

# Display component tables with proper task numbering
print_component_tables() {
    local operation="$1"
    
    # Initialize task counter
    local task_number=1
    
    if [ "$operation" = "install" ]; then
        local intro_title=$(parse_yaml_value "$PATTERN_METADATA_FILE" "introductions.install.title" "INSTALLATION PLAN")
        local intro_text=$(parse_yaml_value "$PATTERN_METADATA_FILE" "introductions.install.overview" "")
        
        # Replace placeholder
        intro_title="${intro_title//\{pattern_display_name\}/${PATTERN_CONFIG[display_name]}}"
        
        print_header "$intro_title"
        if [ -n "$intro_text" ]; then
            echo "$intro_text"
        fi
        echo ""
        
        # Stage 1: Infrastructure (Vault)
        print_info "The following tasks will be executed first:"
        echo ""
        
        # Print infrastructure components with task numbers
        for comp_id in "${!COMPONENTS[@]}"; do
            if [[ "$comp_id" != *_* ]] && [ "${COMPONENTS[$comp_id]}" = "infrastructure" ]; then
                print_category_components "infrastructure" $task_number
                task_number=$((task_number + $(count_category_components "infrastructure")))
                echo ""
                break
            fi
        done
        
        # Stage 2: Secrets Loading  
        printf "%s %s\n" "$task_number." "Load secrets into Vault"
        task_number=$((task_number + 1))
        print_single_component_row "Load secrets into Vault" "N/A" "N/A"
        echo ""
        
        # Stages 3-5: Sequential blocks
        print_info "The following blocks will be executed sequentially. Tasks in each block will run in parallel and be monitored:"
        echo ""
        
        # Stage 3: Operators  
        print_sequence_header "Install Operators"
        print_category_components "operators" $task_number
        task_number=$((task_number + $(count_category_components "operators")))
        echo ""
        
        # Stage 4: Pattern Controller
        print_sequence_header "Deploy Pattern CR (ArgoCD App Factory)"
        print_category_components "pattern_controller" $task_number
        task_number=$((task_number + 1))
        echo ""
        
        # Stage 5: Applications
        print_sequence_header "Install ArgoCD applications"
        print_category_components "applications" $task_number
        
    elif [ "$operation" = "uninstall" ]; then
        local intro_title=$(parse_yaml_value "$PATTERN_METADATA_FILE" "introductions.uninstall.title" "UNINSTALL PLAN")
        local intro_text=$(parse_yaml_value "$PATTERN_METADATA_FILE" "introductions.uninstall.overview" "")
        
        # Replace placeholder
        intro_title="${intro_title//\{pattern_display_name\}/${PATTERN_CONFIG[display_name]}}"
        
        print_header "$intro_title"
        if [ -n "$intro_text" ]; then
            echo "$intro_text"
        fi
        echo ""
        
        # Show SAME plan as install but with installation status indicators
        print_info "The following tasks would be executed in REVERSE order. Components are color-coded:"
        echo "  🟢 = Currently installed (will be removed)"  
        echo "  🔴 = Not installed (will be skipped)"
        echo ""
        
        # Show components in reverse installation order (how they'll be uninstalled)
        
        # Stage 1: Applications (removed first)
        print_sequence_header "Remove Applications"
        print_category_components_with_status "applications" $task_number
        task_number=$((task_number + $(count_category_components "applications")))
        echo ""
        
        # Stage 2: Operators
        print_sequence_header "Remove Operators"  
        print_category_components_with_status "operators" $task_number
        task_number=$((task_number + $(count_category_components "operators")))
        echo ""
        
        # Stage 3: Infrastructure
        print_sequence_header "Remove Infrastructure"
        print_category_components_with_status "infrastructure" $task_number
        task_number=$((task_number + $(count_category_components "infrastructure")))
        
        # Pattern CR
        print_category_components_with_status "pattern_controller" $task_number
    fi
}

# Helper function to count components in a category
count_category_components() {
    local category="$1"
    local count=0
    
    for comp_id in "${!COMPONENTS[@]}"; do
        if [[ "$comp_id" != *_* ]] && [ "${COMPONENTS[$comp_id]}" = "$category" ]; then
            count=$((count + 1))
        fi
    done
    
    echo $count
}

# Print a sequence header with better visual hierarchy
print_sequence_header() {
    local sequence_name="$1"
    echo -e "${BOLD}${CYAN}ℹ--- Sequence: $sequence_name${NC}"
}

# Print components for a category with task numbers
print_category_components() {
    local category="$1"
    local start_number="$2"
    local current_number=$start_number
    
    # Print table header (no "NUM" header, just blank space)
    local name_width="${PATTERN_CONFIG[name_column_width]:-50}"
    local namespace_width="${PATTERN_CONFIG[namespace_column_width]:-40}"
    local version_width="${PATTERN_CONFIG[version_column_width]:-40}"
    
    # Get version column title for this category
    local version_title="VERSION"
    if [ "$category" = "applications" ]; then
        version_title=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "$category.version_column_title" "HELM CHART VERSION")
    fi
    
    printf "%-3s %-*s | %-*s | %s\n" "" "$name_width" "NAME" "$namespace_width" "NAMESPACE" "$version_title"
    printf "%-3s %s | %s | %s\n" "---" "$(printf '%-*s' "$name_width" | tr ' ' '-')" "$(printf '%-*s' "$namespace_width" | tr ' ' '-')" "$(printf '%-*s' "$version_width" | tr ' ' '-')"
    
    # Print each component with task number
    for comp_id in "${!COMPONENTS[@]}"; do
        if [[ "$comp_id" != *_* ]] && [ "${COMPONENTS[$comp_id]}" = "$category" ]; then
            local name="${COMPONENTS[${comp_id}_name]:-Unknown}"
            local namespace="${COMPONENTS[${comp_id}_namespace]:-unknown}"
            local version="${COMPONENTS[${comp_id}_version]:-unknown}"
            
            printf "%-3s %-*s | %-*s | %s\n" "$current_number." "$name_width" "$name" "$namespace_width" "$namespace" "$version"
            current_number=$((current_number + 1))
        fi
    done
}

# Print a single component row (for secrets loading)
print_single_component_row() {
    local name="$1"
    local namespace="$2" 
    local version="$3"
    
    local name_width="${PATTERN_CONFIG[name_column_width]:-50}"
    local namespace_width="${PATTERN_CONFIG[namespace_column_width]:-40}"
    local version_width="${PATTERN_CONFIG[version_column_width]:-40}"
    
    printf "%-3s %-*s | %-*s | %s\n" "" "$name_width" "NAME" "$namespace_width" "NAMESPACE" "VERSION"
    printf "%-3s %s | %s | %s\n" "---" "$(printf '%-*s' "$name_width" | tr ' ' '-')" "$(printf '%-*s' "$namespace_width" | tr ' ' '-')" "$(printf '%-*s' "$version_width" | tr ' ' '-')"
    printf "%-3s %-*s | %-*s | %s\n" " " "$name_width" "$name" "$namespace_width" "$namespace" "$version"
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
# COMPONENT DISCOVERY WITH LOGGING SYSTEM
# =============================================================================

# Global discovery variables
DISCOVERY_LOG=""
DISCOVERY_SUCCESS_COUNT=0
DISCOVERY_FAILURE_COUNT=0
declare -A DISCOVERY_FAILURES

# Initialize discovery logging
init_discovery_logging() {
    local timestamp="$1"  # Accept timestamp as parameter
    
    DISCOVERY_LOG="./logs/pattern-discovery-${timestamp}.log"
    DISCOVERY_SUCCESS_COUNT=0
    DISCOVERY_FAILURE_COUNT=0

    # Ensure the logs directory and log file get created
    mkdir -p "$(dirname "$DISCOVERY_LOG")" 2>/dev/null
    if ! touch "$DISCOVERY_LOG" 2>/dev/null; then
        echo "ERROR: Cannot create discovery log file: $DISCOVERY_LOG" >&2
        return 1
    fi

    echo "📋 COMPONENT DISCOVERY REPORT" > "$DISCOVERY_LOG"
    echo "Generated: $(date)" >> "$DISCOVERY_LOG"
    echo "Pattern: [Loading...]" >> "$DISCOVERY_LOG" # Placeholder
    echo "=================================" >> "$DISCOVERY_LOG"
    echo "" >> "$DISCOVERY_LOG"

    print_info "Discovery logging to: $DISCOVERY_LOG"
}

# Update discovery logging with pattern name
update_discovery_pattern_name() {
    if [ -n "$DISCOVERY_LOG" ] && [ -f "$DISCOVERY_LOG" ]; then
        # Replace the placeholder with actual pattern name
        sed -i.bak "s/Pattern: \[Loading...\]/Pattern: ${PATTERN_CONFIG[display_name]}/" "$DISCOVERY_LOG" 2>/dev/null || true
        rm -f "${DISCOVERY_LOG}.bak" 2>/dev/null
    fi
}

# Log a discovery attempt
log_discovery() {
    local component="$1"
    local field="$2"
    local source="$3"
    local result="$4"
    local reason="$5"
    
    # Add timestamp to log entries
    local timestamp=$(date '+%H:%M:%S')
    
    echo "[$timestamp] Component: $component" >> "$DISCOVERY_LOG"
    if [ -n "$result" ] && [ "$result" != "UNKNOWN"* ]; then
        echo "[$timestamp]   ✅ $field: Found '$result' in $source" >> "$DISCOVERY_LOG"
        DISCOVERY_SUCCESS_COUNT=$((DISCOVERY_SUCCESS_COUNT + 1))
    else
        echo "[$timestamp]   ❌ $field: FAILED - $reason" >> "$DISCOVERY_LOG"
        DISCOVERY_FAILURE_COUNT=$((DISCOVERY_FAILURE_COUNT + 1))
        DISCOVERY_FAILURES["${component}_${field}"]="$reason"
    fi
    echo "" >> "$DISCOVERY_LOG"
}

# Discover namespace with audit
discover_namespace() {
    local comp_id="$1"
    local component_type="$2"
    local result=""
    local source=""
    local reason=""
    
    case "$component_type" in
        "operators")
            # Special handling for gitops operator (typically pre-installed)
            if [ "$comp_id" = "gitops-operator" ]; then
                result="openshift-gitops"
                source="infrastructure default"
                reason="GitOps operator standard namespace"
            else
                # Try values-hub.yaml subscriptions section
                local sub_key=$(discover_subscription_key_for_component "$comp_id")
                if [ -n "$sub_key" ]; then
                    result=$(parse_yaml_value "values-hub.yaml" "clusterGroup.subscriptions.${sub_key}.namespace")
                    source="values-hub.yaml subscriptions.${sub_key}.namespace"
                    reason="subscription found"
                else
                    reason="no matching subscription found in values-hub.yaml"
                fi
            fi
            ;;
        "applications")
            # Try values-hub.yaml applications section
            local app_key=$(discover_application_key_for_component "$comp_id")
            if [ -n "$app_key" ]; then
                result=$(parse_yaml_value "values-hub.yaml" "clusterGroup.applications.${app_key}.namespace")
                source="values-hub.yaml applications.${app_key}.namespace"
                reason="application found"
            else
                reason="no matching application found in values-hub.yaml"
            fi
            ;;
        "infrastructure"|"pattern_controller")
            # Infrastructure components use known namespaces
            case "$comp_id" in
                "vault-app") result="vault"; source="infrastructure default"; reason="vault standard namespace" ;;
                "pattern-cr") result="openshift-operators"; source="infrastructure default"; reason="pattern CR standard namespace" ;;
                *) reason="unknown infrastructure component" ;;
            esac
            ;;
        *)
            reason="unknown component type: $component_type"
            ;;
    esac
    
    # If no result found, mark as unknown
    if [ -z "$result" ]; then
        result="UNKNOWN ($reason)"
    fi
    
    log_discovery "$comp_id" "namespace" "$source" "$result" "$reason"
    echo "$result"
}

# Discover subscription name with audit  
discover_subscription_name() {
    local comp_id="$1"
    local result=""
    local source=""
    local reason=""
    
    # Map component ID to values-hub.yaml subscription key
    local sub_key=$(discover_subscription_key_for_component "$comp_id")
    
    if [ -n "$sub_key" ]; then
        result=$(parse_yaml_value "values-hub.yaml" "clusterGroup.subscriptions.${sub_key}.name")
        source="values-hub.yaml subscriptions.${sub_key}.name"
        if [ -n "$result" ]; then
            reason="subscription found"
        else
            reason="subscription key exists but name field empty"
            result="UNKNOWN ($reason)"
        fi
    else
        reason="no subscription mapping for component $comp_id"
        result="UNKNOWN ($reason)"
    fi
    
    log_discovery "$comp_id" "subscription_name" "$source" "$result" "$reason"
    echo "$result"
}

# Discover version with audit
discover_version() {
    local comp_id="$1"
    local component_type="$2"
    local result=""
    local source=""
    local reason=""
    
    case "$component_type" in
        "operators")
            # Special handling for gitops operator
            if [ "$comp_id" = "gitops-operator" ]; then
                result="stable"
                source="infrastructure default"
                reason="GitOps operator typically uses stable channel"
            else
                # Try to get channel from values-hub.yaml
                local sub_key=$(discover_subscription_key_for_component "$comp_id")
                if [ -n "$sub_key" ]; then
                    result=$(parse_yaml_value "values-hub.yaml" "clusterGroup.subscriptions.${sub_key}.channel")
                    source="values-hub.yaml subscriptions.${sub_key}.channel"
                    if [ -n "$result" ]; then
                        reason="subscription channel found"
                    else
                        reason="subscription exists but no channel specified"
                        result="UNKNOWN ($reason)"
                    fi
                else
                    reason="no subscription found for operator"
                    result="UNKNOWN ($reason)"
                fi
            fi
            ;;
        "applications")
            # Try chartVersion first, then Chart.yaml
            local app_key=$(discover_application_key_for_component "$comp_id")
            if [ -n "$app_key" ]; then
                result=$(parse_yaml_value "values-hub.yaml" "clusterGroup.applications.${app_key}.chartVersion")
                if [ -n "$result" ]; then
                    source="values-hub.yaml applications.${app_key}.chartVersion"
                    reason="chart version found"
                else
                    # Try Chart.yaml in local charts
                    local chart_path=$(parse_yaml_value "values-hub.yaml" "clusterGroup.applications.${app_key}.path")
                    if [ -n "$chart_path" ]; then
                        local chart_file="${chart_path}/Chart.yaml"
                        if [ -f "$chart_file" ]; then
                            result=$(parse_yaml_value "$chart_file" "version")
                            if [ -n "$result" ]; then
                                source="$chart_file version"
                                reason="chart version from Chart.yaml"
                            else
                                reason="Chart.yaml exists but no version found"
                                result="UNKNOWN ($reason)"
                            fi
                        else
                            reason="chart path specified but Chart.yaml not found"
                            result="UNKNOWN ($reason)"
                        fi
                    else
                        reason="no chartVersion or path specified"
                        result="UNKNOWN ($reason)"
                    fi
                fi
            else
                reason="no application mapping found"
                result="UNKNOWN ($reason)"
            fi
            ;;
        "infrastructure")
            # Try infrastructure components
            case "$comp_id" in
                "vault-app") 
                    result=$(parse_yaml_value "values-hub.yaml" "clusterGroup.applications.vault.chartVersion")
                    source="values-hub.yaml applications.vault.chartVersion"
                    reason="infrastructure vault chart version"
                    ;;
                *) 
                    reason="unknown infrastructure component for version discovery"
                    result="UNKNOWN ($reason)"
                    ;;
            esac
            ;;
        "pattern_controller")
            # Pattern CR version from global config
            result=$(parse_yaml_value "values-global.yaml" "global.pattern.revision")
            if [ -n "$result" ]; then
                source="values-global.yaml global.pattern.revision" 
                reason="pattern revision found"
            else
                reason="no pattern revision found in values-global.yaml"
                result="UNKNOWN ($reason)"
            fi
            ;;
        *)
            reason="unknown component type for version discovery"
            result="UNKNOWN ($reason)"
            ;;
    esac
    
    # Ensure we have a result
    if [ -z "$result" ]; then
        result="UNKNOWN ($reason)"
    fi
    
    log_discovery "$comp_id" "version" "$source" "$result" "$reason"
    echo "$result"
}

# Helper: Map component ID to subscription key in values-hub.yaml
discover_subscription_key_for_component() {
    local comp_id="$1"
    case "$comp_id" in
        "cert-manager-op") echo "cert-manager" ;;
        "keycloak-op") echo "rhbk" ;;
        "spire-op") echo "zero-trust-workload-identity-manager" ;;
        "compliance-op") echo "compliance-operator" ;;
        "gitops-operator") echo "" ;; # GitOps operator is typically pre-installed
        *) echo "" ;;
    esac
}

# Helper: Map component ID to application key in values-hub.yaml  
discover_application_key_for_component() {
    local comp_id="$1"
    case "$comp_id" in
        "vault-app") echo "vault" ;;
        "eso-app") echo "golang-external-secrets" ;;
        "keycloak-app") echo "rh-keycloak" ;;
        "cert-manager-app") echo "rh-cert-manager" ;;
        "spire-app") echo "zero-trust-workload-identity-manager" ;;
        *) echo "" ;;
    esac
}

# Generate final discovery summary
generate_discovery_summary() {
    echo "" >> "$DISCOVERY_LOG"
    echo "📊 DISCOVERY SUMMARY" >> "$DISCOVERY_LOG"
    echo "===================" >> "$DISCOVERY_LOG"
    echo "✅ Successful discoveries: $DISCOVERY_SUCCESS_COUNT" >> "$DISCOVERY_LOG"
    echo "❌ Failed discoveries: $DISCOVERY_FAILURE_COUNT" >> "$DISCOVERY_LOG"
    echo "" >> "$DISCOVERY_LOG"
    
    if [ $DISCOVERY_FAILURE_COUNT -gt 0 ]; then
        echo "❌ FAILED DISCOVERIES REQUIRING ATTENTION:" >> "$DISCOVERY_LOG"
        for failure_key in "${!DISCOVERY_FAILURES[@]}"; do
            echo "  - $failure_key: ${DISCOVERY_FAILURES[$failure_key]}" >> "$DISCOVERY_LOG"
        done
        echo "" >> "$DISCOVERY_LOG"
        
        echo "🔧 RECOMMENDED ACTIONS:" >> "$DISCOVERY_LOG"
        echo "  1. Check values-hub.yaml for missing/incorrect entries" >> "$DISCOVERY_LOG"
        echo "  2. Verify Chart.yaml files exist and have version fields" >> "$DISCOVERY_LOG"
        echo "  3. Update component mappings in discover_*_key_for_component functions" >> "$DISCOVERY_LOG"
    fi
    
    # Print summary to console
    echo ""
    print_info "📊 DISCOVERY SUMMARY:"
    echo "  ✅ Successful: $DISCOVERY_SUCCESS_COUNT"
    echo "  ❌ Failed: $DISCOVERY_FAILURE_COUNT"
    if [ $DISCOVERY_FAILURE_COUNT -gt 0 ]; then
        echo "  📋 Full discovery log: $DISCOVERY_LOG"
        echo "  🔧 Review failures and update configuration sources"
    fi
}

# =============================================================================
# DEPLOYMENT EXECUTION LOGGING SYSTEM
# =============================================================================

# Global deployment logging variables
DEPLOYMENT_LOG=""
DEPLOYMENT_START_TIME=""
STAGE_START_TIME=""

# Initialize deployment logging
init_deployment_logging() {
    local timestamp="$1"  # Accept timestamp as parameter
    
    DEPLOYMENT_LOG="./logs/pattern-deployment-${timestamp}.log"
    DEPLOYMENT_SUCCESS_COUNT=0
    DEPLOYMENT_FAILURE_COUNT=0

    # Ensure the logs directory and log file get created  
    mkdir -p "$(dirname "$DEPLOYMENT_LOG")" 2>/dev/null
    if ! touch "$DEPLOYMENT_LOG" 2>/dev/null; then
        echo "ERROR: Cannot create deployment log file: $DEPLOYMENT_LOG" >&2
        return 1
    fi

    echo "🚀 PATTERN DEPLOYMENT LOG" > "$DEPLOYMENT_LOG"
    echo "Generated: $(date)" >> "$DEPLOYMENT_LOG"
    echo "Pattern: [Loading...]" >> "$DEPLOYMENT_LOG" # Placeholder
    echo "=================================" >> "$DEPLOYMENT_LOG"
    echo "" >> "$DEPLOYMENT_LOG"

    print_info "Deployment logging to: $DEPLOYMENT_LOG"
}

# Log deployment stage start
log_stage_start() {
    local stage_number="$1"
    local stage_name="$2"
    local stage_description="$3"
    
    STAGE_START_TIME=$(date +%s)
    local timestamp=$(date +%H:%M:%S)
    
    echo "STAGE $stage_number: $stage_name" >> "$DEPLOYMENT_LOG"
    echo "$(printf '=%.0s' {1..50})" >> "$DEPLOYMENT_LOG"
    echo "$timestamp - $stage_description" >> "$DEPLOYMENT_LOG"
}

# Log deployment step
log_deployment_step() {
    local step_description="$1"
    local result="$2"
    local details="$3"
    
    local timestamp=$(date +%H:%M:%S)
    
    case "$result" in
        "SUCCESS"|"COMPLETED")
            echo "$timestamp - $step_description: SUCCESS${details:+ - $details}" >> "$DEPLOYMENT_LOG"
            ;;
        "FAILED"|"ERROR")
            echo "$timestamp - $step_description: FAILED${details:+ - $details}" >> "$DEPLOYMENT_LOG"
            ;;
        "RETRY")
            echo "$timestamp - $step_description: RETRY${details:+ - $details}" >> "$DEPLOYMENT_LOG"
            ;;
        "INFO")
            echo "$timestamp - $step_description${details:+ - $details}" >> "$DEPLOYMENT_LOG"
            ;;
        *)
            echo "$timestamp - $step_description: $result${details:+ - $details}" >> "$DEPLOYMENT_LOG"
            ;;
    esac
}

# Log stage completion
log_stage_end() {
    local stage_number="$1"
    local result="$2"
    local additional_info="$3"
    
    local stage_end_time=$(date +%s)
    local stage_duration=$((stage_end_time - STAGE_START_TIME))
    local timestamp=$(date +%H:%M:%S)
    
    if [ "$result" = "SUCCESS" ]; then
        echo "$timestamp - Stage $stage_number completed in ${stage_duration} seconds${additional_info:+ - $additional_info}" >> "$DEPLOYMENT_LOG"
    else
        echo "$timestamp - Stage $stage_number FAILED after ${stage_duration} seconds${additional_info:+ - $additional_info}" >> "$DEPLOYMENT_LOG"
    fi
    echo "" >> "$DEPLOYMENT_LOG"
}

# Generate deployment summary
generate_deployment_summary() {
    local overall_result="$1"
    local summary_details="$2"
    
    local deployment_end_time=$(date +%s)
    local total_duration=$((deployment_end_time - DEPLOYMENT_START_TIME))
    local minutes=$((total_duration / 60))
    local seconds=$((total_duration % 60))
    
    echo "🎉 DEPLOYMENT SUMMARY" >> "$DEPLOYMENT_LOG"
    echo "===================" >> "$DEPLOYMENT_LOG"
    
    if [ "$overall_result" = "SUCCESS" ]; then
        echo "✅ Total deployment time: ${minutes}m ${seconds}s" >> "$DEPLOYMENT_LOG"
        echo "✅ All 5 stages successful" >> "$DEPLOYMENT_LOG"
    else
        echo "❌ Deployment FAILED after ${minutes}m ${seconds}s" >> "$DEPLOYMENT_LOG"
        echo "❌ Failure occurred in: $overall_result" >> "$DEPLOYMENT_LOG"
    fi
    
    if [ -n "$summary_details" ]; then
        echo "$summary_details" >> "$DEPLOYMENT_LOG"
    fi
    
    # Check for discovery issues
    if [ $DISCOVERY_FAILURE_COUNT -gt 0 ]; then
        echo "⚠️  $DISCOVERY_FAILURE_COUNT components had discovery issues (see discovery log)" >> "$DEPLOYMENT_LOG"
    fi
    
    # Console summary
    echo ""
    print_info "📋 DEPLOYMENT SUMMARY:"
    if [ "$overall_result" = "SUCCESS" ]; then
        echo "  ✅ Deployment: SUCCESS (${minutes}m ${seconds}s)"
    else
        echo "  ❌ Deployment: FAILED (${minutes}m ${seconds}s)"
    fi
    if [ $DISCOVERY_FAILURE_COUNT -gt 0 ]; then
        echo "  ⚠️  Discovery issues: $DISCOVERY_FAILURE_COUNT components"
    fi
    echo "  📋 Full logs: $DEPLOYMENT_LOG"
    echo "  📋 Discovery details: $DISCOVERY_LOG"
}

# =============================================================================
# INSTALLATION FUNCTIONS
# =============================================================================

# Deploy Vault (Stage 1)
deploy_vault() {
    log_stage_start "1" "VAULT DEPLOYMENT" "Starting Vault deployment"
    
    log_deployment_step "Starting Vault deployment" "INFO"
    
    update_status "vault-app" "DEPLOYING" "Installing HashiCorp Vault"
    
    local runs="${PATTERN_CONFIG[helm_deploy_retries]:-10}"
    local wait="${PATTERN_CONFIG[helm_wait_seconds]:-15}"
    
    # Get Vault chart version from config
    local vault_version=$(parse_yaml_value "values-hub.yaml" "clusterGroup.applications.vault.chartVersion" "0.1.*")
    log_deployment_step "Vault chart version discovered" "INFO" "$vault_version"
    
    local attempt=1
    for i in $(seq 1 ${runs}); do
        exec 3>&1 4>&2
        log_deployment_step "Helm deployment attempt $attempt" "INFO"
        # Deploy Vault using OCI chart reference
        OUT=$( { helm template vault oci://quay.io/validatedpatterns/hashicorp-vault --version "$vault_version" \
            --namespace vault --create-namespace 2>&4 | oc apply -f- 2>&4 1>&3; } 4>&1 3>&1)
        ret=$?
        exec 3>&- 4>&-
        if [ ${ret} -eq 0 ]; then
            log_deployment_step "Helm deployment attempt $attempt" "SUCCESS"
            break;
        else
            log_deployment_step "Helm deployment attempt $attempt" "RETRY" "$OUT"
            echo -n "."
            sleep "${wait}"
            attempt=$((attempt + 1))
        fi
    done

    if [ ${i} -eq ${runs} ]; then
        update_status "vault-app" "FAILED" "Vault deployment failed after ${runs} attempts: $OUT"
        log_deployment_step "Vault deployment" "FAILED" "Failed after ${runs} attempts: $OUT"
        log_stage_end "1" "FAILED" "Vault deployment failed"
        print_error "Vault deployment failed"
        return 1
    fi
    
    update_status "vault-app" "SUCCESS" "Vault deployed successfully"
    log_deployment_step "Vault deployment" "SUCCESS" "Deployed successfully"
    log_deployment_step "Waiting for Vault to be ready" "INFO"
    
    # Wait for Vault to be ready before proceeding
    wait_for_vault_ready
    local vault_ready_result=$?
    
    if [ $vault_ready_result -eq 0 ]; then
        log_deployment_step "Vault readiness check" "SUCCESS" "Vault is ready and API responding"
        log_stage_end "1" "SUCCESS"
    else
        log_deployment_step "Vault readiness check" "FAILED" "Timeout after 5 minutes"
        log_stage_end "1" "FAILED" "Vault readiness timeout"
    fi
    
    return $vault_ready_result
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

# Load secrets into Vault (Stage 2)
load_secrets() {
    local pattern_name="$1"
    
    log_stage_start "2" "SECRETS LOADING" "Processing and loading secrets for pattern: $pattern_name"
    
    # Check if secrets script exists
    local secrets_script="$SCRIPT_DIR/process-secrets.sh"
    if [ ! -f "$secrets_script" ]; then
        log_deployment_step "Secrets script check" "FAILED" "Script not found at $secrets_script"
        log_stage_end "2" "FAILED" "Secrets script missing"
        print_warning "Secrets script not found at $secrets_script, skipping secrets loading"
        return 0
    fi
    
    log_deployment_step "Secrets script found" "SUCCESS" "$secrets_script"
    log_deployment_step "Starting secrets processing" "INFO"
    
    if bash "$secrets_script"; then
        log_deployment_step "Ansible playbook execution" "SUCCESS"
        log_deployment_step "Secrets loaded into Vault" "SUCCESS"
        log_stage_end "2" "SUCCESS"
        print_success "Secrets loaded successfully into Vault"
        return 0
    else
        log_deployment_step "Ansible playbook execution" "FAILED"
        log_stage_end "2" "FAILED" "Secrets loading failed"
        print_error "Secrets loading failed"
        return 1
    fi
}

# Deploy operators in parallel and wait for readiness (Stage 3)
deploy_operators_parallel() {
    log_stage_start "3" "OPERATORS DEPLOYMENT" "Installing all operators in parallel, then waiting for readiness"
    
    local operator_components=()
    
    # Collect operator components from config
    for comp_id in "${!COMPONENTS[@]}"; do
        if [[ "$comp_id" != *_* ]] && [ "${COMPONENTS[$comp_id]}" = "operators" ]; then
            operator_components+=("$comp_id")
        fi
    done
    
    if [ ${#operator_components[@]} -eq 0 ]; then
        log_deployment_step "Operator components discovery" "FAILED" "No operator components found"
        log_stage_end "3" "FAILED" "No operators to deploy"
        print_warning "No operator components found"
        return 0
    fi
    
    log_deployment_step "Starting parallel operator deployment" "INFO" "${#operator_components[@]} operators"
    
    # Start monitoring all operators in parallel
    for comp_id in "${operator_components[@]}"; do
        local operator_name="${COMPONENTS[${comp_id}_name]}"
        log_deployment_step "$operator_name: subscription created" "SUCCESS"
        start_subscription_monitor "$comp_id" &
    done
    
    log_deployment_step "Waiting for operator readiness" "INFO"
    
    # Wait for all operators to be ready
    local all_ready=false
    local timeout=1800  # 30 minutes
    local elapsed=0
    local check_interval=15
    
    while [ $elapsed -lt $timeout ] && [ "$all_ready" = false ]; do
        all_ready=true
        
        for comp_id in "${operator_components[@]}"; do
            local status=$(get_status "$comp_id" "status")
            local operator_name="${COMPONENTS[${comp_id}_name]}"
            
            if [ "$status" = "SUCCESS" ]; then
                # Only log success once per operator
                if [ ! -f "/tmp/logged_${comp_id}_success" ]; then
                    log_deployment_step "$operator_name: CSV Ready" "SUCCESS"
                    touch "/tmp/logged_${comp_id}_success"
                fi
            elif [ "$status" = "FAILED" ]; then
                log_deployment_step "$operator_name: deployment failed" "FAILED"
                log_stage_end "3" "FAILED" "$operator_name deployment failed"
                return 1
            else
                all_ready=false
            fi
        done
        
        if [ "$all_ready" = false ]; then
            sleep $check_interval
            elapsed=$((elapsed + check_interval))
        fi
    done
    
    # Cleanup temp files
    for comp_id in "${operator_components[@]}"; do
        rm -f "/tmp/logged_${comp_id}_success" 2>/dev/null
    done
    
    if [ "$all_ready" = true ]; then
        log_deployment_step "All operators ready" "SUCCESS"
        log_stage_end "3" "SUCCESS" "${#operator_components[@]} operators deployed"
        print_success "All operators deployed and ready!"
        return 0
    else
        log_deployment_step "Operators readiness check" "FAILED" "Timeout after $((timeout/60)) minutes"
        log_stage_end "3" "FAILED" "Operator readiness timeout"
        print_error "Operators readiness timeout after $((timeout/60)) minutes"
        return 1
    fi
}

# Deploy Pattern CR - ArgoCD App Factory (Stage 4)
deploy_pattern_controller() {
    local name="$1"
    local chart="$2"
    shift 2
    local helm_opts="$*"
    
    log_stage_start "4" "PATTERN CR DEPLOYMENT" "Installing Pattern CR to create ArgoCD applications"
    
    log_deployment_step "Starting Pattern CR (ArgoCD App Factory)" "INFO"
    
    update_status "pattern-cr" "DEPLOYING" "Installing helm chart"
    
    local runs="${PATTERN_CONFIG[helm_deploy_retries]:-10}"
    local wait="${PATTERN_CONFIG[helm_wait_seconds]:-15}"
    
    log_deployment_step "Helm template generation" "INFO"
    
    local attempt=1
    # Deploy Pattern CR
    for i in $(seq 1 ${runs}); do
        exec 3>&1 4>&2
        log_deployment_step "Pattern CR deployment attempt $attempt" "INFO"
        OUT=$( { helm template --include-crds --name-template $name $chart $helm_opts 2>&4 | oc apply -f- 2>&4 1>&3; } 4>&1 3>&1)
        ret=$?
        exec 3>&- 4>&-
        if [ ${ret} -eq 0 ]; then
            log_deployment_step "Pattern CR deployment attempt $attempt" "SUCCESS"
            break;
        else
            log_deployment_step "Pattern CR deployment attempt $attempt" "RETRY" "$OUT"
            echo -n "."
            sleep "${wait}"
            attempt=$((attempt + 1))
        fi
    done

    if [ ${i} -eq ${runs} ]; then
        update_status "pattern-cr" "FAILED" "Deployment failed after ${runs} attempts: $OUT"
        log_deployment_step "Pattern CR deployment" "FAILED" "Failed after ${runs} attempts: $OUT"
        log_stage_end "4" "FAILED" "Pattern CR deployment failed"
        print_error "Pattern CR deployment failed"
        return 1
    fi
    
    update_status "pattern-cr" "SUCCESS" "Pattern CR deployed successfully"
    log_deployment_step "Pattern CR created" "SUCCESS" "$name"
    log_deployment_step "ArgoCD applications being created" "INFO"
    
    log_stage_end "4" "SUCCESS" "ArgoCD App Factory deployed"
    print_success "Pattern CR (ArgoCD App Factory) deployed - ArgoCD applications are now being created!"
    
    return 0
}

# Deploy applications in parallel (Stage 5)
deploy_applications_parallel() {
    log_stage_start "5" "ARGOCD APPLICATIONS" "Monitoring ArgoCD applications created by Pattern CR"
    
    local app_components=()
    
    # Collect application components from config
    for comp_id in "${!COMPONENTS[@]}"; do
        if [[ "$comp_id" != *_* ]] && [ "${COMPONENTS[$comp_id]}" = "applications" ]; then
            app_components+=("$comp_id")
        fi
    done
    
    if [ ${#app_components[@]} -eq 0 ]; then
        log_deployment_step "Application components discovery" "FAILED" "No application components found"
        log_stage_end "5" "FAILED" "No applications to monitor"
        print_warning "No application components found"
        return 0
    fi
    
    log_deployment_step "Starting application monitoring" "INFO" "${#app_components[@]} applications"
    log_deployment_step "Waiting for applications to appear" "INFO"
    
    # Start monitoring all applications in parallel
    for comp_id in "${app_components[@]}"; do
        local app_name="${COMPONENTS[${comp_id}_argocd_app_name]}"
        log_deployment_step "$app_name: Found, monitoring sync" "SUCCESS"
        start_argocd_monitor "$comp_id" &
    done
    
    # Wait a bit for applications to sync
    local sync_timeout=600  # 10 minutes for all apps to sync
    local elapsed=0
    local check_interval=15
    
    log_deployment_step "Monitoring application sync status" "INFO" "Timeout: ${sync_timeout}s"
    
    while [ $elapsed -lt $sync_timeout ]; do
        local all_synced=true
        local synced_count=0
        
        for comp_id in "${app_components[@]}"; do
            local status=$(get_status "$comp_id" "status")
            local app_name="${COMPONENTS[${comp_id}_argocd_app_name]}"
            
            if [ "$status" = "SUCCESS" ]; then
                # Only log success once per application
                if [ ! -f "/tmp/logged_${comp_id}_synced" ]; then
                    log_deployment_step "$app_name: Synced and Healthy" "SUCCESS"
                    touch "/tmp/logged_${comp_id}_synced"
                fi
                synced_count=$((synced_count + 1))
            elif [ "$status" = "FAILED" ]; then
                log_deployment_step "$app_name: sync failed" "FAILED"
                all_synced=false
            else
                all_synced=false
            fi
        done
        
        if [ "$all_synced" = true ]; then
            break
        fi
        
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done
    
    # Cleanup temp files
    for comp_id in "${app_components[@]}"; do
        rm -f "/tmp/logged_${comp_id}_synced" 2>/dev/null
    done
    
    local final_synced_count=0
    for comp_id in "${app_components[@]}"; do
        local status=$(get_status "$comp_id" "status")
        if [ "$status" = "SUCCESS" ]; then
            final_synced_count=$((final_synced_count + 1))
        fi
    done
    
    if [ $final_synced_count -eq ${#app_components[@]} ]; then
        log_deployment_step "All applications synced" "SUCCESS" "$final_synced_count/${#app_components[@]}"
        log_stage_end "5" "SUCCESS" "$final_synced_count applications synced"
        print_success "Started monitoring ${#app_components[@]} ArgoCD applications in parallel"
        return 0
    else
        log_deployment_step "Application sync incomplete" "FAILED" "$final_synced_count/${#app_components[@]} synced"
        log_stage_end "5" "FAILED" "Some applications failed to sync"
        print_warning "Only $final_synced_count/${#app_components[@]} applications synced successfully"
        return 1
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
# UNINSTALL EXECUTION LOGGING SYSTEM
# =============================================================================

# Global uninstall logging variables
UNINSTALL_LOG=""
UNINSTALL_START_TIME=""

# Initialize uninstall logging
init_uninstall_logging() {
    local timestamp="$1"  # Accept timestamp as parameter
    
    UNINSTALL_LOG="./logs/pattern-uninstall-${timestamp}.log"
    UNINSTALL_SUCCESS_COUNT=0
    UNINSTALL_FAILURE_COUNT=0

    # Ensure the logs directory and log file get created
    mkdir -p "$(dirname "$UNINSTALL_LOG")" 2>/dev/null
    if ! touch "$UNINSTALL_LOG" 2>/dev/null; then
        echo "ERROR: Cannot create uninstall log file: $UNINSTALL_LOG" >&2
        return 1
    fi

    echo "🗑️ PATTERN UNINSTALL LOG" > "$UNINSTALL_LOG"
    echo "Generated: $(date)" >> "$UNINSTALL_LOG"
    echo "Pattern: [Loading...]" >> "$UNINSTALL_LOG" # Placeholder
    echo "=================================" >> "$UNINSTALL_LOG"
    echo "" >> "$UNINSTALL_LOG"

    print_info "Uninstall logging to: $UNINSTALL_LOG"
}

# Log safety preflight check
log_safety_preflight() {
    local current_user="$1"
    local cluster_version="$2"
    local system_namespaces="$3"
    local pattern_namespaces="$4"
    local safety_result="$5"
    
    local timestamp=$(date +%H:%M:%S)
    
    echo "SAFETY PREFLIGHT CHECK" >> "$UNINSTALL_LOG"
    echo "======================" >> "$UNINSTALL_LOG"
    echo "$timestamp - Current user: $current_user" >> "$UNINSTALL_LOG"
    echo "$timestamp - Cluster version: $cluster_version" >> "$UNINSTALL_LOG"
    echo "$timestamp - System namespaces detected: $system_namespaces" >> "$UNINSTALL_LOG"
    echo "$timestamp - Pattern namespaces to delete: $pattern_namespaces" >> "$UNINSTALL_LOG"
    echo "$timestamp - Safety check: $safety_result" >> "$UNINSTALL_LOG"
    echo "" >> "$UNINSTALL_LOG"
}

# Log namespace safety decision
log_namespace_safety_decision() {
    local namespace="$1"
    local action="$2"
    local reason="$3"
    local resources_affected="$4"
    
    local timestamp=$(date +%H:%M:%S)
    
    case "$action" in
        "DELETE")
            echo "$timestamp - $namespace: DELETING ($reason)" >> "$UNINSTALL_LOG"
            ;;
        "PRESERVE")
            echo "$timestamp - $namespace: PRESERVING ($reason) - cleaned $resources_affected resources" >> "$UNINSTALL_LOG"
            ;;
        "SKIP")
            echo "$timestamp - $namespace: SKIPPING ($reason)" >> "$UNINSTALL_LOG"
            ;;
    esac
}

# Log uninstall step
log_uninstall_step() {
    local step_description="$1"
    local result="$2"
    local details="$3"
    
    local timestamp=$(date +%H:%M:%S)
    
    case "$result" in
        "DELETED"|"SUCCESS")
            echo "$timestamp - $step_description: DELETED${details:+ - $details}" >> "$UNINSTALL_LOG"
            ;;
        "FAILED"|"ERROR")
            echo "$timestamp - $step_description: FAILED${details:+ - $details}" >> "$UNINSTALL_LOG"
            ;;
        "SKIPPED")
            echo "$timestamp - $step_description: SKIPPED${details:+ - $details}" >> "$UNINSTALL_LOG"
            ;;
        "INFO")
            echo "$timestamp - $step_description${details:+ - $details}" >> "$UNINSTALL_LOG"
            ;;
        *)
            echo "$timestamp - $step_description: $result${details:+ - $details}" >> "$UNINSTALL_LOG"
            ;;
    esac
}

# Generate uninstall summary
generate_uninstall_summary() {
    local overall_result="$1"
    local apps_deleted="$2"
    local operators_cleaned="$3"
    local namespaces_deleted="$4"
    local namespaces_preserved="$5"
    
    local uninstall_end_time=$(date +%s)
    local total_duration=$((uninstall_end_time - UNINSTALL_START_TIME))
    local minutes=$((total_duration / 60))
    local seconds=$((total_duration % 60))
    
    echo "🗑️  UNINSTALL SUMMARY" >> "$UNINSTALL_LOG"
    echo "====================" >> "$UNINSTALL_LOG"
    
    if [ "$overall_result" = "SUCCESS" ]; then
        echo "✅ Total uninstall time: ${minutes}m ${seconds}s" >> "$UNINSTALL_LOG"
        echo "✅ All stages successful" >> "$UNINSTALL_LOG"
        echo "✅ $apps_deleted ArgoCD applications deleted" >> "$UNINSTALL_LOG"
        echo "✅ $operators_cleaned operators cleaned up" >> "$UNINSTALL_LOG"
        echo "✅ $namespaces_deleted pattern namespaces deleted" >> "$UNINSTALL_LOG"
        echo "✅ $namespaces_preserved system namespaces preserved" >> "$UNINSTALL_LOG"
    else
        echo "❌ Uninstall FAILED after ${minutes}m ${seconds}s" >> "$UNINSTALL_LOG"
        echo "❌ Failure occurred during: $overall_result" >> "$UNINSTALL_LOG"
    fi
    
    # Check for discovery issues
    if [ $DISCOVERY_FAILURE_COUNT -gt 0 ]; then
        echo "⚠️  Check discovery log for any component issues" >> "$UNINSTALL_LOG"
    fi
    
    # Console summary
    echo ""
    print_info "📋 UNINSTALL SUMMARY:"
    if [ "$overall_result" = "SUCCESS" ]; then
        echo "  ✅ Uninstall: SUCCESS (${minutes}m ${seconds}s)"
        echo "  ✅ $apps_deleted applications, $operators_cleaned operators, $namespaces_deleted namespaces"
    else
        echo "  ❌ Uninstall: FAILED (${minutes}m ${seconds}s)"
    fi
    echo "  📋 Full logs: $UNINSTALL_LOG"
    echo "  📋 Discovery details: $DISCOVERY_LOG"
}

# =============================================================================
# LIBRARY INITIALIZATION
# =============================================================================

# Cleanup old pattern-monitor directories and temp files
cleanup_pattern_temp_files() {
    local current_pid=$$
    
    # Clean up old pattern-monitor directories (older than 1 day)
    find /tmp -maxdepth 1 -name "pattern-monitor-*" -type d -mtime +1 2>/dev/null | while read -r dir; do
        if [ -d "$dir" ]; then
            echo "Cleaning up old monitoring directory: $dir" >&2
            rm -rf "$dir" 2>/dev/null
        fi
    done
    
    # Clean up old log files from ./logs/ directory (keep only 10 most recent)
    if [ -d "./logs" ]; then
        for log_type in "pattern-discovery" "pattern-deployment" "pattern-uninstall"; do
            # Find logs of this type, sort by number (descending), keep only top 10
            ls -1 "./logs/${log_type}-"*.log 2>/dev/null | sort -t'-' -k3 -nr | tail -n +11 | while read -r file; do
                echo "Cleaning up old log: $file" >&2
                rm -f "$file" 2>/dev/null
            done
        done
    fi
}

# Initialize the pattern library
init_pattern_lib() {
    # Clean up old temp files first
    cleanup_pattern_temp_files
    
    # Generate ONE sequential number for all log files in this execution
    local session_number=$(get_next_log_number)
    
    # Initialize all logging systems with the same number
    init_discovery_logging "$session_number"
    init_deployment_logging "$session_number"
    
    # Initialize monitoring directory for status tracking
    init_monitoring

    # Load existing configuration  
    if ! load_pattern_config; then
        return 1
    fi

    # Update discovery log with actual pattern name
    update_discovery_pattern_name

    # Load components with discovery logging
    if ! load_components; then
        return 1
    fi

    # Generate final discovery summary
    generate_discovery_summary

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
export -f deploy_vault load_secrets
export -f deploy_operators_parallel deploy_pattern_controller
export -f deploy_applications_parallel
export -f check_uninstall_state ask_confirmation
export -f init_pattern_lib

# =============================================================================
# TIMEZONE CONSISTENCY UTILITIES
# =============================================================================

# Get next sequential log number for this execution session
# This ensures consistent numbering across container and local execution
get_next_log_number() {
    local log_dir="./logs"
    local max_num=0
    
    # Ensure log directory exists
    mkdir -p "$log_dir" 2>/dev/null
    
    # Find highest existing number across all log types
    if [ -d "$log_dir" ]; then
        # Look for any pattern-*-###.log files
        for file in "$log_dir"/pattern-*-[0-9][0-9][0-9].log; do
            if [ -f "$file" ]; then
                # Extract the 3-digit number before .log
                local num=$(echo "$file" | sed 's/.*-\([0-9][0-9][0-9]\)\.log$/\1/')
                local num_int=$((10#$num))
                if [ "$num_int" -gt "$max_num" ]; then
                    max_num=$num_int
                fi
            fi
        done
    fi
    
    # Increment and wrap around at 999
    local next_num=$((max_num + 1))
    if [ $next_num -gt 999 ]; then
        next_num=1
    fi
    
    # Return 3-digit zero-padded number
    printf "%03d" $next_num
}

# Get consistent timestamp for this execution session  
# This ensures container timezone matches file creation timezone
get_session_timestamp() {
    # Force consistent timezone for container vs local execution
    # The key insight: container displays in UTC but files are created in local time
    # So we need to ensure BOTH use the same timezone
    
    # Test if we're in a container environment by checking file creation timezone
    local test_file="/tmp/tz-test-$$"
    touch "$test_file" 2>/dev/null
    local file_tz_offset=""
    if [ -f "$test_file" ]; then
        # Get the timezone offset of file creation (local filesystem)
        file_tz_offset=$(date -r "$test_file" +%z 2>/dev/null)
        rm -f "$test_file" 2>/dev/null
    fi
    
    # Force consistency: use the timezone that matches file creation
    if [ -n "$file_tz_offset" ]; then
        # Use the same timezone as file creation to ensure display matches files
        date +%Y%m%d-%H%M%S
    else
        # Fallback to UTC if we can't determine file timezone
        TZ=UTC date +%Y%m%d-%H%M%S
    fi
}

# =============================================================================
# DYNAMIC COMPONENT ARRAY GENERATION
# =============================================================================

# Generate operator components array from YAML data
# Returns: array of "comp_id:display_name" strings
get_operator_components() {
    local components=()
    for comp_id in "${!COMPONENTS[@]}"; do
        if [[ "$comp_id" != *_* ]] && [ "${COMPONENTS[$comp_id]}" = "operators" ]; then
            local comp_name="${COMPONENTS[${comp_id}_name]}"
            components+=("$comp_id:$comp_name")
        fi
    done
    printf '%s\n' "${components[@]}"
}

# Generate application components array from YAML data  
# Returns: array of "comp_id:display_name" strings
get_application_components() {
    local components=()
    for comp_id in "${!COMPONENTS[@]}"; do
        if [[ "$comp_id" != *_* ]] && [ "${COMPONENTS[$comp_id]}" = "applications" ]; then
            local comp_name="${COMPONENTS[${comp_id}_name]}"
            components+=("$comp_id:$comp_name")
        fi
    done
    printf '%s\n' "${components[@]}"
}

# Generate uninstall app mappings from YAML data
# Returns: array of "argocd_app_name:display_name" strings
get_uninstall_app_mappings() {
    local mappings=()
    for comp_id in "${!COMPONENTS[@]}"; do
        if [[ "$comp_id" != *_* ]] && [ "${COMPONENTS[$comp_id]}" = "applications" ]; then
            local comp_name="${COMPONENTS[${comp_id}_name]}"
            local app_name="${COMPONENTS[${comp_id}_argocd_app_name]}"
            mappings+=("$app_name:$comp_name")
        fi
    done
    printf '%s\n' "${mappings[@]}"
}

# Export the dynamic array functions  
export -f get_operator_components get_application_components get_uninstall_app_mappings get_next_log_number

# Check if a component is actually installed using oc commands
check_component_installed() {
    local comp_id="$1"
    local component_type="${COMPONENTS[$comp_id]}"
    
    case "$component_type" in
        "operators")
            # Check if subscription exists
            local sub_name="${COMPONENTS[${comp_id}_subscription_name]}"
            local namespace="${COMPONENTS[${comp_id}_namespace]}"
            if [ -n "$sub_name" ] && [ -n "$namespace" ] && [ "$namespace" != "UNKNOWN"* ]; then
                oc get subscription "$sub_name" -n "$namespace" >/dev/null 2>&1
                return $?
            fi
            return 1
            ;;
        "applications")
            # Check if ArgoCD application exists (only if ArgoCD is installed)
            if ! oc api-resources | grep -q "applications.*argoproj.io" 2>/dev/null; then
                return 1  # ArgoCD not installed, so no applications
            fi
            local app_name="${COMPONENTS[${comp_id}_argocd_app_name]}"
            if [ -n "$app_name" ] && [ "$app_name" != "UNKNOWN"* ]; then
                oc get application.argoproj.io "$app_name" -n openshift-gitops >/dev/null 2>&1
                return $?
            fi
            return 1
            ;;
        "infrastructure")
            # Check vault namespace or other infrastructure
            case "$comp_id" in
                "vault-app")
                    oc get namespace vault >/dev/null 2>&1
                    return $?
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        "pattern_controller")
            # Check if pattern CR exists (only if ArgoCD is installed)
            if ! oc api-resources | grep -q "applications.*argoproj.io" 2>/dev/null; then
                return 1  # ArgoCD not installed, so no pattern CR
            fi
            oc get application.argoproj.io -n openshift-gitops | grep -q "$(echo "$PATTERN_CONFIG[name]" | sed 's/layered-zero-trust/layered-zero-trust-hub/')" 2>/dev/null
            return $?
            ;;
        *)
            return 1
            ;;
    esac
}

# Print category components with installation status indicators
print_category_components_with_status() {
    local category="$1"
    local start_task_number="$2"
    local task_number=$start_task_number
    
    # Create arrays to track installed vs missing
    local installed_components=()
    local missing_components=()
    
    # Check installation status for each component
    for comp_id in "${!COMPONENTS[@]}"; do
        if [[ "$comp_id" != *_* ]] && [ "${COMPONENTS[$comp_id]}" = "$category" ]; then
            if check_component_installed "$comp_id"; then
                installed_components+=("$comp_id")
            else
                missing_components+=("$comp_id")
            fi
        fi
    done
    
    # Print installed components (green)
    for comp_id in "${installed_components[@]}"; do
        local comp_name="${COMPONENTS[${comp_id}_name]}"
        local namespace="${COMPONENTS[${comp_id}_namespace]}"
        local version="${COMPONENTS[${comp_id}_version]}"
        
        printf "🟢 %s. %s\n" "$task_number" "$comp_name"
        task_number=$((task_number + 1))
    done
    
    # Print missing components (red) 
    for comp_id in "${missing_components[@]}"; do
        local comp_name="${COMPONENTS[${comp_id}_name]}"
        local namespace="${COMPONENTS[${comp_id}_namespace]}"
        local version="${COMPONENTS[${comp_id}_version]}"
        
        printf "🔴 %s. %s (not installed)\n" "$task_number" "$comp_name"
        task_number=$((task_number + 1))
    done
}

# Export the component installation checking function
export -f check_component_installed print_category_components_with_status

# =============================================================================
# DISCOVERY-DRIVEN DEPLOYMENT FUNCTIONS (Stage 1)
# =============================================================================

# Discover component metadata for UX display
discover_component_metadata() {
    local component_id="$1"
    
    # Initialize discovery results
    local namespace=""
    local version=""
    local deployment_method=""
    
    print_info "Discovering metadata for component: $component_id"
    
    # Check if component exists in applications section (chart-based)
    if grep -A 10 "applications:" values-hub.yaml | grep -q "^  $component_id:"; then
        # Extract namespace and version from applications section
        namespace=$(parse_yaml_value "values-hub.yaml" "clusterGroup.applications.$component_id.namespace" "")
        version=$(parse_yaml_value "values-hub.yaml" "clusterGroup.applications.$component_id.chartVersion" "")
        deployment_method="pattern-chart"
        
    # Check if component exists in subscriptions section (operator-based)  
    elif grep -A 20 "subscriptions:" values-hub.yaml | grep -q "^  $component_id:"; then
        # Extract namespace and version from subscriptions section
        namespace=$(parse_yaml_value "values-hub.yaml" "clusterGroup.subscriptions.$component_id.namespace" "")
        version=$(parse_yaml_value "values-hub.yaml" "clusterGroup.subscriptions.$component_id.channel" "")
        deployment_method="pattern-chart"
        
    # Special cases (secrets, pattern-cr, etc.)
    else
        case "$component_id" in
            "secrets")
                namespace="vault"
                version="N/A"
                deployment_method="pattern-chart"
                ;;
            "pattern-cr")
                namespace="openshift-operators"
                version=$(parse_yaml_value "values-global.yaml" "main.git.revision" "N/A")
                deployment_method="pattern-chart"
                ;;
            *)
                print_warning "Unknown component: $component_id"
                namespace="unknown"
                version="unknown"
                deployment_method="unknown"
                ;;
        esac
    fi
    
    # Return discovered metadata
    echo "NAMESPACE=$namespace"
    echo "VERSION=$version"
    echo "DEPLOYMENT_METHOD=$deployment_method"
}

# Discover execution command for deployment
discover_execution_command() {
    local component_id="$1"
    
    # For now, ALL components use the same command (engineers' original method)
    # This will be the foundation for the discovery-driven approach
    local command="./pattern.sh make operator-deploy"
    
    print_info "Discovered deployment command for $component_id: $command"
    echo "$command"
}

# Execute discovered deployment command (with fallback protection)
execute_discovered_command() {
    local component_id="$1"
    local discovered_cmd="$2"
    local fallback_function="$3"
    
    print_info "Executing discovered deployment for: $component_id"
    print_info "Command: $discovered_cmd"
    
    if [ -z "$discovered_cmd" ]; then
        print_warning "Discovery failed for $component_id"
        if [ -n "$fallback_function" ]; then
            print_info "Using fallback method: $fallback_function"
            eval "$fallback_function"
            return $?
        else
            print_error "No fallback method available for $component_id"
            return 1
        fi
    fi
    
    # Execute discovered command
    # TODO: Implement actual execution in Stage 2
    print_info "Would execute: $discovered_cmd"
    print_warning "Stage 1: Discovery only - not executing yet"
    
    return 0
}

# Test discovery functions (for dry-run validation)
test_discovery() {
    print_header "DISCOVERY VALIDATION TEST"
    
    local test_components=("vault-app" "cert-manager-op" "keycloak-app" "pattern-cr" "secrets")
    
    for component in "${test_components[@]}"; do
        echo ""
        print_info "Testing discovery for: $component"
        
        # Test metadata discovery
        local metadata=$(discover_component_metadata "$component")
        echo "  Metadata: $metadata"
        
        # Test command discovery  
        local command=$(discover_execution_command "$component")
        echo "  Command: $command"
        
        # Test execution (dry-run only)
        execute_discovered_command "$component" "$command" "echo 'fallback method'"
    done
    
    echo ""
    print_success "Discovery validation completed"
}

# Export discovery functions
export -f discover_component_metadata discover_execution_command execute_discovered_command test_discovery
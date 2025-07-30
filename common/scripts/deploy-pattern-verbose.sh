#!/bin/bash
set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

# Global tracking
declare -A COMPONENT_STATUS
declare -A COMPONENT_START_TIME
declare -A COMPONENT_DETAILS
declare -a MONITOR_PIDS
MONITOR_DIR="/tmp/pattern-monitor-$$"
DEPLOYMENT_START_TIME=$(date +%s)

# Create monitoring directory
mkdir -p "$MONITOR_DIR"

# Cleanup function
cleanup() {
    print_info "Cleaning up monitoring processes..."
    for pid in "${MONITOR_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    rm -rf "$MONITOR_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Time formatting function
format_time() {
    local seconds=$1
    local minutes=$((seconds / 60))
    local remaining_seconds=$((seconds % 60))
    printf "%02d:%02d" $minutes $remaining_seconds
}

# Print functions (same as before)
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

# Status file functions
update_status() {
    local component=$1
    local status=$2
    local details=$3
    
    # Only update timestamp if status actually changed
    local current_status=$(get_status "$component" | cut -d'|' -f1)
    local timestamp=$(date +%s)
    
    if [ "$current_status" != "$status" ]; then
        # Status changed, use new timestamp
        echo "$status|$details|$timestamp" > "$MONITOR_DIR/$component.status"
    else
        # Status same, keep original timestamp
        local original_timestamp=$(get_status "$component" | cut -d'|' -f3)
        echo "$status|$details|$original_timestamp" > "$MONITOR_DIR/$component.status"
    fi
}

get_status() {
    local component=$1
    if [ -f "$MONITOR_DIR/$component.status" ]; then
        cat "$MONITOR_DIR/$component.status"
    else
        echo "PENDING||$(date +%s)"
    fi
}

# Dynamic version extraction from live pattern configuration
get_live_pattern_info() {
    print_info "Analyzing pattern configuration..."
    
    # Get pattern version from reliable source (values-global.yaml)
    PATTERN_VERSION=$(grep "clusterGroupChartVersion:" values-global.yaml 2>/dev/null | awk '{print $2}' | tr -d '"')
    [ -z "$PATTERN_VERSION" ] && PATTERN_VERSION="not found in values-global.yaml"
    
    # Try to get operator channels from containerized make show
    local show_output=$(./pattern.sh make show 2>&1)
    local make_exit_code=$?
    
    if [ $make_exit_code -ne 0 ] || [ -z "$show_output" ]; then
        print_info "WARNING: 'make show' in container failed (exit code: $make_exit_code)"
        GITOPS_CHANNEL="container failed"
        PATTERNS_CHANNEL="container failed"  
    else
        # Extract GitOps channel from ConfigMap
        GITOPS_CHANNEL=$(echo "$show_output" | grep "gitops.channel:" | awk '{print $2}')
        [ -z "$GITOPS_CHANNEL" ] && GITOPS_CHANNEL="not found in 'make show'"
        
        # Extract Patterns operator channel from Subscription  
        PATTERNS_CHANNEL=$(echo "$show_output" | grep "channel:" | awk '{print $2}')
        [ -z "$PATTERNS_CHANNEL" ] && PATTERNS_CHANNEL="not found in 'make show'"
    fi
    
    # Parse application info from values files (simpler and more reliable)
    parse_values_files
}

parse_values_files() {
    # Extract application chart versions from values-hub.yaml
    VAULT_CR="hashicorp-vault $(get_chart_version "vault")"
    GOLANG_EXTERNAL_SECRETS_CR="golang-external-secrets $(get_chart_version "golang-external-secrets")"
    RH_KEYCLOAK_CR="rh-keycloak $(get_chart_version "rh-keycloak")"
    RH_CERT_MANAGER_CR="rh-cert-manager $(get_chart_version "rh-cert-manager")"
    ZERO_TRUST_CR="zero-trust-workload-identity-manager $(get_chart_version "zero-trust-workload-identity-manager")"
}

# Extract operator channels from values-hub.yaml (fallback)
get_operator_channel() {
    local operator_key="$1"
    local channel=$(grep -A 5 "^    $operator_key:" values-hub.yaml 2>/dev/null | grep "channel:" | awk '{print $2}')
    if [ -n "$channel" ]; then
        echo "$channel"
    else
        echo "unknown"
    fi
}

get_pattern_version() {
    # Use dynamic pattern version from make show, add git info if available
    local git_info=""
    if git rev-parse --short HEAD >/dev/null 2>&1; then
        local branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        local commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        git_info="$branch@$commit"
    fi
    
    if [ -n "$git_info" ]; then
        echo "$PATTERN_VERSION ($git_info)"
    else
        echo "$PATTERN_VERSION"
    fi
}

get_chart_version() {
    local app_name="$1"
    # Extract chartVersion from values-hub.yaml for specific application
    # Note: apps are indented with 4 spaces, some use 'path:' for local charts
    local version=$(grep -A 6 "^    $app_name:" values-hub.yaml 2>/dev/null | grep "chartVersion:" | awk '{print $2}' | tr -d '"')
    if [ -n "$version" ]; then
        echo "$version"
    else
        # Check if it's a local chart (has 'path:')
        local chart_path=$(grep -A 6 "^    $app_name:" values-hub.yaml 2>/dev/null | grep "path:" | awk '{print $2}')
        if [ -n "$chart_path" ]; then
            # Get version from local Chart.yaml
            local local_version=$(grep "^version:" "$chart_path/Chart.yaml" 2>/dev/null | awk '{print $2}')
            if [ -n "$local_version" ]; then
                echo "$local_version"
            else
                echo "unknown"
            fi
        else
            echo "unknown"
        fi
    fi
}

# Component listing (enhanced with live pattern analysis)
list_components() {
    print_header "LAYERED ZERO TRUST PATTERN - ASYNC INSTALLATION PLAN"
    
    # Get live pattern information
    get_live_pattern_info
    
    print_info "The following components will be monitored in parallel:"
    echo
    
            # INFRASTRUCTURE TABLE
        print_info "INFRASTRUCTURE:"
        printf "%-50s | %-40s | %s\n" "NAME" "NAMESPACE" "VERSION"
        printf "%-50s | %-40s | %s\n" "--------------------------------------------------" "----------------------------------------" "----------------------------------------"
        
        local pattern_version=$(get_pattern_version)
        printf "%-50s | %-40s | %s\n" "Pattern CR" "openshift-operators" "$pattern_version"
        printf "%-50s | %-40s | %s\n" "Patterns Operator" "openshift-operators" "$PATTERNS_CHANNEL"
        printf "%-50s | %-40s | %s\n" "GitOps Operator" "openshift-operators" "$GITOPS_CHANNEL"
    echo
    
            # OPERATORS TABLE
        print_info "OPERATORS INSTALLED BY THE PATTERN:"
        printf "%-50s | %-40s | %s\n" "NAME" "NAMESPACE" "VERSION"
        printf "%-50s | %-40s | %s\n" "--------------------------------------------------" "----------------------------------------" "----------------------------------------"
        
        local cert_channel=$(get_operator_channel "cert-manager")
        local rhbk_channel=$(get_operator_channel "rhbk")
        local ztw_channel=$(get_operator_channel "zero-trust-workload-identity-manager")
        local comp_channel=$(get_operator_channel "compliance-operator")
        
        printf "%-50s | %-40s | %s\n" "Cert Manager Operator" "cert-manager-operator" "$cert_channel"
        printf "%-50s | %-40s | %s\n" "Keycloak Operator" "keycloak-system" "$rhbk_channel"
        printf "%-50s | %-40s | %s\n" "Zero Trust Workload Identity Manager Operator" "zero-trust-workload-identity-manager" "$ztw_channel"
        printf "%-50s | %-40s | %s\n" "Compliance Operator" "openshift-compliance" "$comp_channel"
    echo
    
            # ARGOCD APPLICATIONS TABLE
        print_info "ZERO TRUST COMPONENTS (INSTALLED WITH ARGOCD):"
        printf "%-50s | %-40s | %s\n" "NAME" "NAMESPACE" "HELM CHART VERSION"
        printf "%-50s | %-40s | %s\n" "--------------------------------------------------" "----------------------------------------" "----------------------------------------"
        
        printf "%-50s | %-40s | %s\n" "HashiCorp Vault" "vault" "$VAULT_CR"
        printf "%-50s | %-40s | %s\n" "Golang External Secrets" "golang-external-secrets" "$GOLANG_EXTERNAL_SECRETS_CR"
        printf "%-50s | %-40s | %s\n" "Red Hat Keycloak" "keycloak-system" "$RH_KEYCLOAK_CR"
        printf "%-50s | %-40s | %s\n" "Red Hat Cert Manager" "cert-manager" "$RH_CERT_MANAGER_CR"
        printf "%-50s | %-40s | %s\n" "Zero Trust SPIRE/SPIFFE" "zero-trust-workload-identity-manager" "$ZERO_TRUST_CR"
    echo
    
    print_info "DEPLOYMENT FLOW:"
    echo "  Pattern CR → Secrets Loading → Patterns Operator → GitOps + Direct Operators → ArgoCD Applications → Component Deployment"
    echo
}



# Confirmation
ask_confirmation() {
    echo
    echo -ne "${BOLD}${YELLOW}Do you want to proceed with async installation? (y/N): ${NC}"
    read -r response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            return 0
            ;;
        *)
            echo "Installation cancelled by user."
            exit 0
            ;;
    esac
}

# Core pattern deployment (same as before)
deploy_pattern() {
    local name=$1
    local chart=$2
    shift 2
    local helm_opts="$*"
    
    print_header "DEPLOYING CORE PATTERN INFRASTRUCTURE"
    print_info "Installing pattern base infrastructure..."
    
    update_status "core-pattern" "DEPLOYING" "Installing helm chart"
    
    RUNS=10
    WAIT=15
    
    for i in $(seq 1 ${RUNS}); do
        exec 3>&1 4>&2
        OUT=$( { helm template --include-crds --name-template $name $chart $helm_opts 2>&4 | oc apply -f- 2>&4 1>&3; } 4>&1 3>&1)
        ret=$?
        exec 3>&- 4>&-
        if [ ${ret} -eq 0 ]; then
            break;
        else
            echo -n "."
            sleep "${WAIT}"
        fi
    done

    if [ ${i} -eq ${RUNS} ]; then
        update_status "core-pattern" "FAILED" "Deployment failed after ${RUNS} attempts: $OUT"
        print_error "Core pattern deployment failed"
        return 1
    else
        update_status "core-pattern" "SUCCESS" "Infrastructure deployed successfully"
        print_success "Core pattern infrastructure deployed - starting async monitoring"
        return 0
    fi
}

# Background Patterns operator monitor
monitor_patterns_operator() {
    update_status "patterns-operator" "WAITING" "Waiting for Patterns operator subscription"
    
    # Wait for subscription to be created
    local timeout=300  # 5 minutes to appear
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if oc get subscription patterns-operator -n openshift-operators >/dev/null 2>&1; then
            update_status "patterns-operator" "INSTALLING" "Subscription found, installing Patterns operator"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    if [ $elapsed -ge $timeout ]; then
        update_status "patterns-operator" "FAILED" "Subscription not created after $timeout seconds"
        return 1
    fi
    
    # Monitor installation
    timeout=600  # 10 minutes to install
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local install_state=$(oc get subscription patterns-operator -n openshift-operators -o jsonpath='{.status.state}' 2>/dev/null)
        if [[ "$install_state" == "AtLatestKnown" ]]; then
            update_status "patterns-operator" "SUCCESS" "Patterns operator installed successfully"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    update_status "patterns-operator" "FAILED" "Installation timeout after $timeout seconds"
    return 1
}

# Background GitOps operator monitor
monitor_gitops_operator() {
    update_status "gitops-operator" "WAITING" "Waiting for GitOps operator subscription"
    
    # Wait for subscription to be created
    local timeout=300  # 5 minutes to appear
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if oc get subscription openshift-gitops-operator -n openshift-operators >/dev/null 2>&1; then
            update_status "gitops-operator" "INSTALLING" "Subscription found, installing GitOps operator"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    if [ $elapsed -ge $timeout ]; then
        update_status "gitops-operator" "FAILED" "Subscription not created after $timeout seconds"
        return 1
    fi
    
    # Monitor installation
    timeout=600  # 10 minutes to install
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local install_state=$(oc get subscription openshift-gitops-operator -n openshift-operators -o jsonpath='{.status.state}' 2>/dev/null)
        if [[ "$install_state" == "AtLatestKnown" ]]; then
            update_status "gitops-operator" "SUCCESS" "GitOps operator installed successfully"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    update_status "gitops-operator" "FAILED" "Installation timeout after $timeout seconds"
    return 1
}

# Background operator monitor
monitor_operator() {
    local op_name=$1
    local op_namespace=$2
    local component_name=$3
    
    update_status "$component_name" "WAITING" "Waiting for subscription creation"
    
    # Wait for subscription to be created
    local timeout=300  # 5 minutes to appear
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if oc get subscription $op_name -n $op_namespace >/dev/null 2>&1; then
            update_status "$component_name" "INSTALLING" "Subscription found, installing operator"
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    if [ $elapsed -ge $timeout ]; then
        update_status "$component_name" "FAILED" "Subscription not created after $timeout seconds"
        return 1
    fi
    
    # Monitor installation
    timeout=600  # 10 minutes to install
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local install_state=$(oc get subscription $op_name -n $op_namespace -o jsonpath='{.status.state}' 2>/dev/null)
        if [[ "$install_state" == "AtLatestKnown" ]]; then
            update_status "$component_name" "SUCCESS" "Operator installed successfully"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    update_status "$component_name" "FAILED" "Installation timeout after $timeout seconds"
    return 1
}

# Background application monitor
monitor_application() {
    local app_name=$1
    local component_name=$2
    
    update_status "$component_name" "WAITING" "Waiting for ArgoCD application"
    
    # Wait for application to appear
    local timeout=180  # 3 minutes for ArgoCD to create app
    local elapsed=0
    local app_namespace=""
    
    while [ $elapsed -lt $timeout ]; do
        # Find the application in any namespace
        local app_info=$(oc get applications.argoproj.io -A --no-headers 2>/dev/null | grep "^[^[:space:]]*[[:space:]]*$app_name[[:space:]]" | head -1)
        if [ -n "$app_info" ]; then
            app_namespace=$(echo "$app_info" | awk '{print $1}')
            update_status "$component_name" "SYNCING" "Application found in $app_namespace, monitoring sync"
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    if [ -z "$app_namespace" ]; then
        update_status "$component_name" "FAILED" "Application not found after $timeout seconds"
        return 1
    fi
    
    # Monitor sync and health
    timeout=900  # 15 minutes for app to be healthy
    elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local sync_status=$(oc get application.argoproj.io $app_name -n $app_namespace -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        local health_status=$(oc get application.argoproj.io $app_name -n $app_namespace -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        
        if [[ "$sync_status" == "Synced" && "$health_status" == "Healthy" ]]; then
            update_status "$component_name" "SUCCESS" "Synced and Healthy"
            return 0
        elif [[ "$sync_status" == "OutOfSync" ]]; then
            update_status "$component_name" "SYNCING" "Sync: $sync_status, Health: $health_status"
        else
            update_status "$component_name" "PROGRESSING" "Sync: $sync_status, Health: $health_status"
        fi
        
        sleep 15
        elapsed=$((elapsed + 15))
    done
    
    update_status "$component_name" "FAILED" "Timeout - Sync: $sync_status, Health: $health_status"
    return 1
}

# Start all background monitors
start_monitors() {
    print_header "STARTING ASYNC COMPONENT MONITORING"
    
    # Start Patterns operator monitor
    print_info "Starting Patterns operator monitor..."
    monitor_patterns_operator &
    MONITOR_PIDS+=($!)
    
    # Start GitOps operator monitor
    print_info "Starting GitOps operator monitor..."
    monitor_gitops_operator &
    MONITOR_PIDS+=($!)
    
    # Start operator monitors
    print_info "Starting operator monitors..."
    monitor_operator "openshift-cert-manager-operator" "cert-manager-operator" "cert-manager-op" &
    MONITOR_PIDS+=($!)
    
    monitor_operator "rhbk-operator" "keycloak-system" "keycloak-op" &
    MONITOR_PIDS+=($!)
    
    monitor_operator "openshift-zero-trust-workload-identity-manager" "zero-trust-workload-identity-manager" "spire-op" &
    MONITOR_PIDS+=($!)
    
    monitor_operator "compliance-operator" "openshift-compliance" "compliance-op" &
    MONITOR_PIDS+=($!)
    
    # Start application monitors  
    print_info "Starting application monitors..."
    monitor_application "vault" "vault-app" &
    MONITOR_PIDS+=($!)
    
    monitor_application "golang-external-secrets" "eso-app" &
    MONITOR_PIDS+=($!)
    
    monitor_application "rh-keycloak" "keycloak-app" &
    MONITOR_PIDS+=($!)
    
    monitor_application "rh-cert-manager" "cert-manager-app" &
    MONITOR_PIDS+=($!)
    
    monitor_application "zero-trust-workload-identity-manager" "spire-app" &
    MONITOR_PIDS+=($!)
    
    print_success "All monitors started! Monitoring ${#MONITOR_PIDS[@]} components in parallel"
}

# Live dashboard
show_live_dashboard() {
    local infrastructure_components=(
        "core-pattern:Core Pattern Infrastructure"
        "patterns-operator:Patterns Operator"
        "gitops-operator:GitOps Operator"
    )
    
    local operator_components=(
        "cert-manager-op:Cert Manager Operator" 
        "keycloak-op:Keycloak Operator"
        "spire-op:Zero Trust Workload Identity Manager Operator"
        "compliance-op:Compliance Operator"
    )
    
    local application_components=(
        "vault-app:HashiCorp Vault"
        "eso-app:Golang External Secrets"
        "keycloak-app:Red Hat Keycloak" 
        "cert-manager-app:Red Hat Cert Manager"
        "spire-app:Zero Trust SPIRE/SPIFFE"
    )
    
    print_header "LIVE MONITORING DASHBOARD"
    
    local max_wait=1800  # 30 minutes total
    local start_time=$(date +%s)
    local update_count=0
    
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
        
        # Infrastructure section
        echo -e "${BOLD}${CYAN}INFRASTRUCTURE${NC}"
        printf "%-50s %-12s %-8s %s\n" "COMPONENT" "STATUS" "IN STATUS" "DETAILS"
        echo "─────────────────────────────────────────────────────────────────────────────────────────────"
        
        for comp in "${infrastructure_components[@]}"; do
            IFS=':' read -r comp_id comp_name <<< "$comp"
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
        done
        
        echo
        echo -e "${BOLD}${CYAN}OPERATORS${NC}"
        printf "%-50s %-12s %-8s %s\n" "COMPONENT" "STATUS" "IN STATUS" "DETAILS"
        echo "─────────────────────────────────────────────────────────────────────────────────────────────"
        
        for comp in "${operator_components[@]}"; do
            IFS=':' read -r comp_id comp_name <<< "$comp"
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
        done
        
        echo
        echo -e "${BOLD}${CYAN}ZERO TRUST COMPONENTS (INSTALLED WITH ARGOCD)${NC}"
        printf "%-50s %-12s %-8s %s\n" "COMPONENT" "STATUS" "IN STATUS" "DETAILS"
        echo "─────────────────────────────────────────────────────────────────────────────────────────────"
        
        for comp in "${application_components[@]}"; do
            IFS=':' read -r comp_id comp_name <<< "$comp"
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
        done
        
        echo
        local total_components=$((${#infrastructure_components[@]} + ${#operator_components[@]} + ${#application_components[@]}))
        echo "Progress: Success=$success_count, Failed=$failed_count, Active=$((total_components - success_count - failed_count))"
        
        if [ "$all_done" = true ]; then
            print_success "All components completed!"
            break
        fi
        
        sleep 15
        update_count=$((update_count + 1))
    done
}

# Secrets loading (before application monitoring)
load_secrets() {
    print_header "LOADING SECRETS (BEFORE APPLICATION MONITORING)"
    print_info "Loading secrets before ArgoCD applications start syncing..."
    
    update_status "secrets" "LOADING" "Processing secrets"
    
    if common/scripts/process-secrets.sh "$1"; then
        update_status "secrets" "SUCCESS" "Secrets loaded successfully"
        print_success "Secrets loaded successfully"
    else
        update_status "secrets" "FAILED" "Secrets loading failed"
        print_error "Secrets loading failed"
    fi
}

# Final summary
print_final_summary() {
    print_header "ASYNC INSTALLATION SUMMARY"
    
    local total_time=$(($(date +%s) - DEPLOYMENT_START_TIME))
    echo "Total installation time: $(format_time $total_time)"
    echo
    
    # Read final status of all components
    local success_count=0
    local failed_count=0
    
    print_info "Final Component Status:"
    echo
    
    local components=(
        "core-pattern:Core Pattern Infrastructure"
        "patterns-operator:Patterns Operator"
        "gitops-operator:GitOps Operator"
        "cert-manager-op:Cert Manager Operator" 
        "keycloak-op:Keycloak Operator"
        "spire-op:Zero Trust Workload Identity Manager Operator"
        "compliance-op:Compliance Operator"
        "vault-app:HashiCorp Vault"
        "eso-app:Golang External Secrets"
        "keycloak-app:Red Hat Keycloak" 
        "cert-manager-app:Red Hat Cert Manager"
        "spire-app:Zero Trust SPIRE/SPIFFE"
        "secrets:Secrets Loading"
    )
    
    for comp in "${components[@]}"; do
        IFS=':' read -r comp_id comp_name <<< "$comp"
        local status_line=$(get_status "$comp_id")
        IFS='|' read -r status details timestamp <<< "$status_line"
        
        if [[ "$status" == "SUCCESS" ]]; then
            print_success "$comp_name"
            success_count=$((success_count + 1))
        else
            print_error "$comp_name - $details"
            failed_count=$((failed_count + 1))
        fi
    done
    
    echo
    print_info "Statistics:"
    echo "  Total components: ${#components[@]}"
    echo "  Successful: $success_count"
    echo "  Failed: $failed_count"
    
    if [ $failed_count -eq 0 ]; then
        echo
        print_success "🎉 COMPLETE ASYNC INSTALLATION SUCCESS! 🎉"
        print_info "All components deployed successfully using parallel monitoring!"
    else
        echo
        print_warning "Some components failed. Check ArgoCD console for details."
        print_info "You can check overall status with: make argo-healthcheck"
        return 1
    fi
}

# Main execution
main() {
    local name=$1
    local chart=$2
    shift 2
    local helm_opts="$*"
    
    # Show plan and component table
    list_components
    ask_confirmation
    
    # Deploy core pattern
    if ! deploy_pattern "$name" "$chart" $helm_opts; then
        print_error "Core pattern deployment failed. Aborting."
        exit 1
    fi
    
    # Load secrets BEFORE starting application monitoring
    load_secrets "$name"
    
    # Start all background monitors
    start_monitors
    
    # Show live dashboard
    show_live_dashboard
    
    # Show final summary
    print_final_summary
}

# Execute main function with all arguments
main "$@" 
#!/bin/bash
set -euo pipefail

# Configuration
PATTERN_NAME="${1:-$(basename "$(pwd)")}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

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

# Check what exists before we start
check_initial_state() {
    print_header "VERBOSE PATTERN UNINSTALL v3.8 (COMPLETE-ARGOCD-AWARE) - INITIAL STATE CHECK"
    
    print_info "Scanning for ALL pattern resources (not just CRs)..."
    
    local pattern_count=$(oc get pattern "$PATTERN_NAME" -n openshift-operators --no-headers 2>/dev/null | wc -l | tr -d ' ')
    local apps_count=$(oc get applications.argoproj.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    local namespaces_count=$(oc get ns 2>/dev/null | grep -E "(vault|keycloak|cert-manager|zero-trust|external-secrets)" | wc -l | tr -d ' ')
    local pods_count=0
    
    # Count pods in pattern namespaces
    for ns in vault keycloak-system cert-manager cert-manager-operator golang-external-secrets zero-trust-workload-identity-manager layered-zero-trust-hub; do
        local ns_pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        pods_count=$((pods_count + ns_pods))
    done
    
    local subscriptions_count=$(oc get subscriptions -A --no-headers 2>/dev/null | grep -E "(cert-manager|rhbk|compliance|zero-trust)" | wc -l | tr -d ' ')
    local csvs_count=$(oc get csv -A --no-headers 2>/dev/null | grep -E "(cert-manager|keycloak|rhbk|compliance|zero-trust)" | wc -l | tr -d ' ')
    
    echo "Current Pattern Footprint:"
    echo "  Pattern CR '$PATTERN_NAME': $pattern_count"
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
    print_header "COMPLETE PATTERN CLEANUP CONFIRMATION"
    print_info "Pattern: $PATTERN_NAME"
    print_warning "This will perform a COMPLETE cleanup including:"
    echo "  • ArgoCD applications (deleted in reverse installation order)"
    echo "  • ArgoCD/GitOps operator itself"
    echo "  • All operator installations (CSVs and subscriptions)"
    echo "  • All pattern namespaces and their contents"
    echo "  • All deployed workloads (pods, services, deployments, etc.)"
    echo "  • Pattern CR itself"
    echo
    print_warning "This uses reverse-order ArgoCD app deletion (mimicking manual ArgoCD UI deletion)!"
    
    echo
    echo -ne "${BOLD}${YELLOW}Do you want to proceed with COMPLETE uninstall? (y/N): ${NC}"
    read -r response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            ;;
        *)
            echo "Uninstall cancelled by user."
            exit 0
            ;;
    esac
}

# Resource mapping table (same as install script)
show_resource_mapping() {
    print_header "COMPONENT RESOURCE MAPPING"
    print_info "Components to be removed (logical → technical names):"
    echo
    
    echo "ARGOCD APPLICATIONS (to be deleted in reverse order):"
    printf "  %-35s → %s\n" "Zero Trust Workload Identity Manager" "zero-trust-workload-identity-manager"
    printf "  %-35s → %s\n" "Red Hat Cert Manager" "rh-cert-manager"
    printf "  %-35s → %s\n" "Red Hat Keycloak" "rh-keycloak"
    printf "  %-35s → %s\n" "External Secrets Controller" "golang-external-secrets"
    printf "  %-35s → %s\n" "HashiCorp Vault" "vault"
    echo
    
    echo "OPERATORS (to be uninstalled):"
    printf "  %-35s → %s\n" "OpenShift Cert Manager Operator" "openshift-cert-manager-operator"
    printf "  %-35s → %s\n" "Red Hat Build of Keycloak Operator" "rhbk-operator"
    printf "  %-35s → %s\n" "Zero Trust Workload Identity Manager" "openshift-zero-trust-workload-identity-manager"
    printf "  %-35s → %s\n" "Compliance Operator" "compliance-operator"
    printf "  %-35s → %s\n" "Red Hat OpenShift GitOps" "openshift-gitops-operator"
    printf "  %-35s → %s\n" "Validated Patterns Operator" "patterns-operator"
    echo
    
    echo "PATTERN CONTROL:"
    printf "  %-35s → %s\n" "Main Pattern Application" "layered-zero-trust-hub (managed by Pattern CR)"
    printf "  %-35s → %s\n" "Pattern Custom Resource" "layered-zero-trust"
    echo
}

# Clean GitOps operator (ArgoCD)
cleanup_gitops_operator() {
    print_header "STEP 2: CLEANUP GITOPS OPERATOR (ARGOCD)"
    
    print_info "Removing GitOps operator subscription..."
    
    # Remove GitOps operator subscription
    if oc get subscription openshift-gitops-operator -n openshift-operators >/dev/null 2>&1; then
        print_info "Removing GitOps operator subscription"
        oc delete subscription openshift-gitops-operator -n openshift-operators --timeout=60s >/dev/null 2>&1 || true
    fi
    
    # Remove GitOps operator CSV
    local gitops_csv=$(oc get csv -n openshift-operators --no-headers 2>/dev/null | grep "openshift-gitops-operator" | awk '{print $1}')
    if [ -n "$gitops_csv" ]; then
        print_info "Uninstalling GitOps operator: $gitops_csv"
        oc delete csv "$gitops_csv" -n openshift-operators --timeout=60s >/dev/null 2>&1 || true
    fi
    
    print_success "GitOps operator removed"
}

# Clean other operator installations (CSVs)
cleanup_other_operators() {
    print_header "STEP 3: CLEANUP OTHER OPERATOR INSTALLATIONS (CSVs)"
    
    print_info "Finding and removing pattern-related operators..."
    
    # Remove CSVs (this actually uninstalls the operators)
    local csvs=$(oc get csv -A --no-headers 2>/dev/null | grep -E "(cert-manager|keycloak|rhbk|compliance|zero-trust)" | awk '{print $2 ":" $1}')
    
    if [ -n "$csvs" ]; then
        echo "$csvs" | while IFS=':' read -r csv_name namespace; do
            print_info "Uninstalling operator: $csv_name from $namespace"
            oc delete csv "$csv_name" -n "$namespace" --timeout=60s >/dev/null 2>&1 || true
        done
        print_success "Operator installations removed"
    else
        print_info "No pattern-related operators found"
    fi
    
    # Clean any remaining subscriptions
    local subscriptions=$(oc get subscriptions -A --no-headers 2>/dev/null | grep -E "(cert-manager|rhbk|compliance|zero-trust)")
    if [ -n "$subscriptions" ]; then
        echo "$subscriptions" | while read -r line; do
            local namespace=$(echo "$line" | awk '{print $1}')
            local sub_name=$(echo "$line" | awk '{print $2}')
            oc delete subscription "$sub_name" -n "$namespace" --timeout=30s >/dev/null 2>&1 || true
        done
    fi
}

# Clean ArgoCD applications in reverse installation order  

cleanup_argocd_applications() {
    print_header "STEP 1: CLEANUP ARGOCD APPLICATIONS (REVERSE ORDER)"
    
    # First delete the main ArgoCD application (parent controller)
    local main_app_name="${pattern_name}-hub"
    print_info "Deleting main ArgoCD application: $main_app_name (parent controller for Pattern CR)"
    
    local main_app_info=$(oc get applications.argoproj.io "$main_app_name" -n openshift-gitops --no-headers 2>/dev/null)
    if [ -n "$main_app_info" ]; then
        local status=$(echo "$main_app_info" | awk '{print $2"-"$3}')
        print_info "Found: $main_app_name in openshift-gitops (Status: $status) - Deleting..."
        oc delete application.argoproj.io "$main_app_name" -n openshift-gitops --wait=false >/dev/null 2>&1 || true
        sleep 5  # Brief pause for deletion to propagate
    else
        print_info "Main ArgoCD application $main_app_name not found (already deleted)"
    fi
    
    # Then delete remaining ArgoCD applications in reverse installation order
    local app_mappings=(
        "zero-trust-workload-identity-manager:Zero Trust Workload Identity Manager"
        "rh-cert-manager:Red Hat Cert Manager" 
        "rh-keycloak:Red Hat Keycloak"
        "golang-external-secrets:External Secrets Controller"
        "vault:HashiCorp Vault"
    )
    
    print_info "Deleting remaining ArgoCD applications in reverse installation order..."
    
    local deleted_count=0
    for mapping in "${app_mappings[@]}"; do
        IFS=':' read -r app_name logical_name <<< "$mapping"
        
        # Find the application namespace
        local app_info=$(oc get applications.argoproj.io -A --no-headers 2>/dev/null | grep "^[^[:space:]]*[[:space:]]*$app_name[[:space:]]")
        
        if [ -n "$app_info" ]; then
            local namespace=$(echo "$app_info" | awk '{print $1}')
            local status=$(echo "$app_info" | awk '{print $3"-"$4}')
            
            print_info "Deleting: $logical_name → $app_name (in $namespace) - Status: $status"
            
            # Delete the application (mimicking manual ArgoCD UI deletion)
            oc delete application.argoproj.io "$app_name" -n "$namespace" --wait=false >/dev/null 2>&1 || true
            deleted_count=$((deleted_count + 1))
            
            # Brief pause between deletions for ArgoCD to process
            sleep 5
        else
            print_info "Application not found: $logical_name → $app_name (already deleted or never existed)"
        fi
    done
    
    if [ $deleted_count -eq 0 ]; then
        print_success "No ArgoCD applications found to delete"
        return 0
    fi
    
    print_info "Issued delete commands for $deleted_count applications, monitoring cleanup..."
    
    # Wait for graceful deletion with countdown
    local elapsed=0
    local max_wait=180  # 3 minutes for ArgoCD apps
    print_info "Waiting up to $max_wait seconds for graceful deletion..."
    while [ $elapsed -lt $max_wait ]; do
        local remaining=$(oc get applications.argoproj.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$remaining" = "0" ]; then
            print_success "All applications deleted gracefully"
            return 0
        fi
        
        local time_left=$((max_wait - elapsed))
        local minutes=$((time_left / 60))
        local seconds=$((time_left % 60))
        echo "⏱️  ${remaining} apps remaining - Time left: $(printf "%02d:%02d" $minutes $seconds) - $(date '+%H:%M:%S')"
        
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    # Force remove finalizers from stuck applications
    print_warning "Some applications stuck - removing finalizers..."
    local stuck_apps=$(oc get applications.argoproj.io -A --no-headers 2>/dev/null)
    
    if [ -n "$stuck_apps" ]; then
        echo "$stuck_apps" | while read -r line; do
            local namespace=$(echo "$line" | awk '{print $1}')
            local app_name=$(echo "$line" | awk '{print $2}')
            print_info "Removing finalizers from $app_name..."
            oc patch application.argoproj.io "$app_name" -n "$namespace" --type='merge' -p='{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
        done
        
        sleep 5
        local final_count=$(oc get applications.argoproj.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$final_count" = "0" ]; then
            print_success "All stuck applications cleaned up"
        else
            print_warning "$final_count applications still remain"
        fi
    fi
}

# Clean Patterns operator
cleanup_patterns_operator() {
    print_header "STEP 4: CLEANUP PATTERNS OPERATOR"
    
    print_info "Removing Patterns operator..."
    
    # Remove Patterns operator subscription
    if oc get subscription patterns-operator -n openshift-operators >/dev/null 2>&1; then
        print_info "Removing Patterns operator subscription"
        oc delete subscription patterns-operator -n openshift-operators --timeout=60s >/dev/null 2>&1 || true
    fi
    
    # Remove Patterns operator CSV
    local patterns_csv=$(oc get csv -n openshift-operators --no-headers 2>/dev/null | grep "patterns-operator" | awk '{print $1}')
    if [ -n "$patterns_csv" ]; then
        print_info "Uninstalling Patterns operator: $patterns_csv"
        oc delete csv "$patterns_csv" -n openshift-operators --timeout=60s >/dev/null 2>&1 || true
    fi
    
    print_success "Patterns operator removed"
}

# Clean namespaces (only non-operator namespaces now)
cleanup_namespaces() {
    print_header "STEP 5: CLEANUP PATTERN NAMESPACES"
    
    local pattern_namespaces=(
        "vault"
        "keycloak-system" 
        "cert-manager"
        "cert-manager-operator"
        "golang-external-secrets"
        "zero-trust-workload-identity-manager"
        "layered-zero-trust-hub"
    )
    
    print_info "Removing pattern namespaces..."
    
    for ns in "${pattern_namespaces[@]}"; do
        if oc get ns "$ns" >/dev/null 2>&1; then
            print_info "Deleting namespace: $ns"
            oc delete ns "$ns" --timeout=60s >/dev/null 2>&1 || {
                print_warning "Namespace $ns stuck, checking for blocking resources..."
                
                # Check for stuck ArgoCD server instances with finalizers first
                local stuck_argocds=$(oc get argocds.argoproj.io -n "$ns" --no-headers 2>/dev/null | awk '{print $1}')
                if [ -n "$stuck_argocds" ]; then
                    print_info "Found stuck ArgoCD server instances in $ns, removing finalizers..."
                    echo "$stuck_argocds" | while read -r argocd_name; do
                        if [ -n "$argocd_name" ]; then
                            print_info "Removing finalizers from ArgoCD server: $argocd_name"
                            oc patch argocd.argoproj.io "$argocd_name" -n "$ns" --type='merge' -p='{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
                        fi
                    done
                    sleep 5
                fi
                
                # Check for stuck ArgoCD applications with finalizers second
                local stuck_apps=$(oc get applications.argoproj.io -n "$ns" --no-headers 2>/dev/null | awk '{print $1}')
                if [ -n "$stuck_apps" ]; then
                    print_info "Found stuck ArgoCD applications in $ns, removing finalizers..."
                    echo "$stuck_apps" | while read -r app_name; do
                        if [ -n "$app_name" ]; then
                            print_info "Removing finalizers from ArgoCD application: $app_name"
                            oc patch application.argoproj.io "$app_name" -n "$ns" --type='merge' -p='{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
                        fi
                    done
                    sleep 5
                fi
                
                # Check for stuck pods second
                local stuck_pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null | awk '{print $1}')
                if [ -n "$stuck_pods" ]; then
                    print_info "Found stuck pods in $ns, force deleting..."
                    echo "$stuck_pods" | while read -r pod_name; do
                        if [ -n "$pod_name" ]; then
                            print_info "Force deleting pod: $pod_name"
                            oc delete pod "$pod_name" -n "$ns" --force --grace-period=0 >/dev/null 2>&1 || true
                        fi
                    done
                    sleep 10
                fi
                
                print_warning "Namespace $ns still stuck, forcing cleanup with namespace finalizer removal..."
                # Force remove finalizers
                oc patch ns "$ns" --type='merge' -p='{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
                oc delete ns "$ns" --force --grace-period=0 >/dev/null 2>&1 || true
            }
        fi
    done
    
    print_success "Pattern namespaces cleaned"
}

# Clean Pattern CR
cleanup_pattern_cr() {
    print_header "STEP 6: CLEANUP PATTERN CR (AFTER CONTROLLING APPS ARE GONE)"
    
    local pattern_count=$(oc get pattern "$PATTERN_NAME" -n openshift-operators --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$pattern_count" = "0" ]; then
        print_success "Pattern CR already deleted"
        return 0
    fi
    
    print_info "Attempting graceful Pattern CR deletion (non-blocking)..."
    timeout 30s oc delete pattern "$PATTERN_NAME" -n openshift-operators --wait=false >/dev/null 2>&1 || true
    print_info "Pattern CR delete command issued (non-blocking)"
    
    # Wait for graceful deletion with countdown
    local elapsed=0
    local max_wait=60  # 1 minute for Pattern CR (children already gone)
    print_info "Waiting up to $max_wait seconds for Pattern CR deletion..."
    while [ $elapsed -lt $max_wait ]; do
        local remaining=$(oc get pattern "$PATTERN_NAME" -n openshift-operators --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$remaining" = "0" ]; then
            print_success "Pattern CR deleted gracefully"
            return 0
        fi
        
        local time_left=$((max_wait - elapsed))
        local minutes=$((time_left / 60))
        local seconds=$((time_left % 60))
        echo "⏱️  Pattern CR still exists - Time left: $(printf "%02d:%02d" $minutes $seconds) - $(date '+%H:%M:%S')"
        
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    print_warning "Pattern CR deletion timed out - forcing cleanup..."
    # Force remove finalizers if stuck
    oc patch pattern "$PATTERN_NAME" -n openshift-operators --type='merge' -p='{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    
    # Verify final deletion
    sleep 5
    local final_count=$(oc get pattern "$PATTERN_NAME" -n openshift-operators --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$final_count" = "0" ]; then
        print_success "Pattern CR forcefully removed"
    else
        print_error "Failed to remove Pattern CR - manual intervention may be required"
    fi
}

# Final verification
final_verification() {
    print_header "FINAL VERIFICATION"
    
    print_info "Performing complete cleanup verification..."
    
    local pattern_count=$(oc get pattern "$PATTERN_NAME" -n openshift-operators --no-headers 2>/dev/null | wc -l | tr -d ' ')
    local apps_count=$(oc get applications.argoproj.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    local namespaces_count=$(oc get ns 2>/dev/null | grep -E "(vault|keycloak|cert-manager|zero-trust|external-secrets)" | wc -l | tr -d ' ')
    local pods_count=0
    
    # Count remaining pods and identify stuck ones
    for ns in vault keycloak-system cert-manager cert-manager-operator golang-external-secrets zero-trust-workload-identity-manager layered-zero-trust-hub; do
        local ns_pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        pods_count=$((pods_count + ns_pods))
        
        # Report stuck resources for debugging
        if [ "$ns_pods" -gt 0 ]; then
            print_warning "Namespace $ns still has $ns_pods pods remaining"
            oc get pods -n "$ns" --no-headers 2>/dev/null | while read -r line; do
                local pod_name=$(echo "$line" | awk '{print $1}')
                local pod_status=$(echo "$line" | awk '{print $3}')
                print_info "  Stuck pod: $pod_name (Status: $pod_status)"
            done
        fi
        
        # Also check for stuck ArgoCD servers
        local ns_argocds=$(oc get argocds.argoproj.io -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$ns_argocds" -gt 0 ]; then
            print_warning "Namespace $ns still has $ns_argocds ArgoCD server instances remaining"
            oc get argocds.argoproj.io -n "$ns" --no-headers 2>/dev/null | while read -r line; do
                local argocd_name=$(echo "$line" | awk '{print $1}')
                print_info "  Stuck ArgoCD server: $argocd_name"
            done
        fi
        
        # Also check for stuck ArgoCD applications
        local ns_apps=$(oc get applications.argoproj.io -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$ns_apps" -gt 0 ]; then
            print_warning "Namespace $ns still has $ns_apps ArgoCD applications remaining"
            oc get applications.argoproj.io -n "$ns" --no-headers 2>/dev/null | while read -r line; do
                local app_name=$(echo "$line" | awk '{print $1}')
                local app_status=$(echo "$line" | awk '{print $2"-"$3}')
                print_info "  Stuck ArgoCD app: $app_name (Status: $app_status)"
            done
        fi
    done
    
    local subscriptions_count=$(oc get subscriptions -A --no-headers 2>/dev/null | grep -E "(cert-manager|rhbk|compliance|zero-trust)" | wc -l | tr -d ' ')
    local csvs_count=$(oc get csv -A --no-headers 2>/dev/null | grep -E "(cert-manager|keycloak|rhbk|compliance|zero-trust)" | wc -l | tr -d ' ')
    
    echo
    echo "Final Status:"
    echo "  Pattern CR '$PATTERN_NAME': $pattern_count"
    echo "  ArgoCD applications: $apps_count"
    echo "  Pattern namespaces: $namespaces_count"
    echo "  Running pods: $pods_count"
    echo "  Operator subscriptions: $subscriptions_count"
    echo "  Installed operators (CSVs): $csvs_count"
    
    local total_remaining=$((pattern_count + apps_count + namespaces_count + pods_count + subscriptions_count + csvs_count))
    
    if [ $total_remaining -eq 0 ]; then
        echo
        print_success "🎉 COMPLETE CLEANUP SUCCESS! 🎉"
        print_info "Pattern '$PATTERN_NAME' has been COMPLETELY uninstalled!"
        print_info "Cluster is truly clean - no residue left!"
        return 0
    else
        echo
        print_warning "Some resources remain ($total_remaining total)"
        print_info "Check remaining resources manually if needed"
        return 1
    fi
}

# Main execution function
main() {
    local pattern_name="$1"
    
    if [ -z "$pattern_name" ]; then
        print_error "Usage: $0 <pattern-name>"
        print_info "Example: $0 layered-zero-trust"
        exit 1
    fi
    
    PATTERN_NAME="$pattern_name"
    
    # Check if anything needs to be cleaned up
    if ! check_initial_state; then
        exit 0
    fi
    
    # Show resource mapping
    show_resource_mapping
    
    # Ask for confirmation
    ask_confirmation
    
    print_header "STARTING COMPLETE PATTERN CLEANUP v3.8 (COMPLETE-ARGOCD-AWARE)"
    print_info "Using ArgoCD applications cleanup (including main app), then reverse-order cleanup!"
    
    # Execute cleanup steps (ArgoCD-aware approach - reverse order)
    cleanup_argocd_applications  # Step 1: Delete ArgoCD Apps in reverse order (including main app)
    cleanup_gitops_operator      # Step 2: GitOps Operator (ArgoCD itself)
    cleanup_other_operators      # Step 3: Other Operators (cert-manager, etc.)
    cleanup_patterns_operator    # Step 4: Patterns Operator
    cleanup_namespaces          # Step 5: Pattern namespaces  
    cleanup_pattern_cr          # Step 6: Pattern CR (after apps that control it are gone)
    
    # Final verification
    final_verification
    exit_code=$?
    
    print_header "COMPLETE UNINSTALL FINISHED"
    if [ $exit_code -eq 0 ]; then
        print_success "ArgoCD-aware cleanup completed successfully! 🎉"
        print_info "Perfect cleanup: reverse-order app deletion + operator cleanup + no residue!"
    else
        print_warning "Cleanup completed but some resources may remain"
        print_info "Check the verification output above for details"
    fi
    
    exit $exit_code
}

# Execute main function
main "$@" 
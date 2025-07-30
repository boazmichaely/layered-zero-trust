#!/usr/bin/env bash
set -euo pipefail

# New Config-Driven Uninstall Script v2.0
# Uses shared pattern library for configuration-driven pattern uninstallation

# Get script directory and source the shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pattern-lib.sh"

# Configuration
PATTERN_NAME="${1:-$(basename "$(pwd)")}"

# =============================================================================
# UNINSTALL IMPLEMENTATION FUNCTIONS
# =============================================================================

# Clean ArgoCD applications in reverse installation order
cleanup_argocd_applications() {
    print_header "STEP 1: CLEANUP ARGOCD APPLICATIONS (REVERSE ORDER)"
    
    # First delete ArgoCD applications in reverse order (children before parent)
    print_info "Deleting ArgoCD applications in reverse installation order..."
    
    local deleted_count=0
    
    # Get ArgoCD apps from config (NO HARDCODING!)
    local argocd_apps=()
    for comp_id in "${!COMPONENTS[@]}"; do
        if [[ "$comp_id" != *_* ]] && [ "${COMPONENTS[$comp_id]}" = "applications" ]; then
            argocd_apps+=("$comp_id")
        fi
    done
    
    # Reverse the array to get deletion order (last installed = first deleted)
    local reversed_apps=()
    for (( i=${#argocd_apps[@]}-1 ; i>=0 ; i-- )); do
        reversed_apps+=("${argocd_apps[i]}")
    done
    
    for comp_id in "${reversed_apps[@]}"; do
        local comp_name="${COMPONENTS[${comp_id}_name]:-Unknown}"
        local app_name="${COMPONENTS[${comp_id}_argocd_app_name]:-unknown}"
        
        # Find the application namespace
        local app_info=$(oc get applications.argoproj.io -A --no-headers 2>/dev/null | grep "^[^[:space:]]*[[:space:]]*$app_name[[:space:]]")
        
        if [ -n "$app_info" ]; then
            local namespace=$(echo "$app_info" | awk '{print $1}')
            local status=$(echo "$app_info" | awk '{print $3"-"$4}')
            
            print_info "Deleting: $comp_name → $app_name (in $namespace) - Status: $status"
            oc delete application.argoproj.io "$app_name" -n "$namespace" --wait=false >/dev/null 2>&1 || true
            deleted_count=$((deleted_count + 1))
            sleep 5
        else
            print_info "Application not found: $comp_name → $app_name (already deleted or never existed)"
        fi
    done
    
    # Now delete the main ArgoCD application (parent controller) AFTER children
    local main_app_name="${PATTERN_NAME}-hub"
    print_info "Deleting main ArgoCD application: $main_app_name (parent controller - deleted AFTER children)"
    
    local argocd_namespace="${COMPONENTS[gitops-operator_namespace]:-openshift-gitops}"
    local main_app_info=$(oc get applications.argoproj.io "$main_app_name" -n "$argocd_namespace" --no-headers 2>/dev/null)
    if [ -n "$main_app_info" ]; then
        local status=$(echo "$main_app_info" | awk '{print $2"-"$3}')
        print_info "Found: $main_app_name in $argocd_namespace (Status: $status) - Deleting..."
        oc delete application.argoproj.io "$main_app_name" -n "$argocd_namespace" --wait=false >/dev/null 2>&1 || true
        deleted_count=$((deleted_count + 1))
        sleep 5
    else
        print_info "Main ArgoCD application $main_app_name not found (already deleted)"
    fi
    
    if [ $deleted_count -eq 0 ]; then
        print_success "No ArgoCD applications found to delete"
        return 0
    fi
    
    print_info "Issued delete commands for $deleted_count applications (including main app), monitoring cleanup..."
    
    # Wait for graceful deletion with countdown
    local elapsed=0
    local max_wait=180
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

# Clean GitOps operator
cleanup_gitops_operator() {
    print_header "STEP 2: CLEANUP GITOPS OPERATOR (ARGOCD)"
    
    print_info "Removing GitOps operator subscription..."
    
    # Use config to get GitOps operator details
    local gitops_subscription="${COMPONENTS[gitops-operator_subscription_name]:-openshift-gitops-operator}"
    local gitops_namespace="${COMPONENTS[gitops-operator_namespace]:-openshift-operators}"
    
    if oc get subscription "$gitops_subscription" -n "$gitops_namespace" >/dev/null 2>&1; then
        print_info "Removing GitOps operator subscription"
        oc delete subscription "$gitops_subscription" -n "$gitops_namespace" --timeout=60s >/dev/null 2>&1 || true
    fi
    
    # Remove GitOps operator CSV
    local gitops_csv=$(oc get csv -n "$gitops_namespace" --no-headers 2>/dev/null | grep "openshift-gitops-operator" | awk '{print $1}')
    if [ -n "$gitops_csv" ]; then
        print_info "Uninstalling GitOps operator: $gitops_csv"
        oc delete csv "$gitops_csv" -n "$gitops_namespace" --timeout=60s >/dev/null 2>&1 || true
    fi
    
    print_success "GitOps operator removed"
}

# Clean other operators using config
cleanup_other_operators() {
    print_header "STEP 3: CLEANUP OTHER OPERATOR INSTALLATIONS (CSVs)"
    
    print_info "Finding and removing pattern-related operators..."
    
    # Get cleanup patterns from config
    local csv_pattern=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "uninstall.cleanup_patterns.csvs" "(cert-manager|keycloak|rhbk|compliance|zero-trust)")
    
    # Remove CSVs (this actually uninstalls the operators)
    local csvs=$(oc get csv -A --no-headers 2>/dev/null | grep -E "$csv_pattern" | awk '{print $2 ":" $1}')
    
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
    local subscription_pattern=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "uninstall.cleanup_patterns.subscriptions" "(cert-manager|rhbk|compliance|zero-trust)")
    local subscriptions=$(oc get subscriptions -A --no-headers 2>/dev/null | grep -E "$subscription_pattern")
    if [ -n "$subscriptions" ]; then
        echo "$subscriptions" | while read -r line; do
            local namespace=$(echo "$line" | awk '{print $1}')
            local sub_name=$(echo "$line" | awk '{print $2}')
            oc delete subscription "$sub_name" -n "$namespace" --timeout=30s >/dev/null 2>&1 || true
        done
    fi
}

# Clean Patterns operator
cleanup_patterns_operator() {
    print_header "STEP 4: CLEANUP PATTERNS OPERATOR"
    
    print_info "Removing Patterns operator..."
    
    # Use config to get Patterns operator details
    local patterns_subscription="${COMPONENTS[patterns-operator_subscription_name]:-patterns-operator}"
    local patterns_namespace="${COMPONENTS[patterns-operator_namespace]:-openshift-operators}"
    
    if oc get subscription "$patterns_subscription" -n "$patterns_namespace" >/dev/null 2>&1; then
        print_info "Removing Patterns operator subscription"
        oc delete subscription "$patterns_subscription" -n "$patterns_namespace" --timeout=60s >/dev/null 2>&1 || true
    fi
    
    # Remove Patterns operator CSV
    local patterns_csv=$(oc get csv -n "$patterns_namespace" --no-headers 2>/dev/null | grep "patterns-operator" | awk '{print $1}')
    if [ -n "$patterns_csv" ]; then
        print_info "Uninstalling Patterns operator: $patterns_csv"
        oc delete csv "$patterns_csv" -n "$patterns_namespace" --timeout=60s >/dev/null 2>&1 || true
    fi
    
    print_success "Patterns operator removed"
}

# Clean namespaces using config
cleanup_namespaces() {
    print_header "STEP 5: CLEANUP PATTERN NAMESPACES"
    
    # Get namespaces from config (NO HARDCODING!)
    local pattern_namespaces=()
    
    # Extract all unique namespaces from component definitions
    for comp_id in "${!COMPONENTS[@]}"; do
        if [[ "$comp_id" != *_* ]]; then
            local ns="${COMPONENTS[${comp_id}_namespace]}"
            if [ -n "$ns" ]; then
                # Add to array if not already present
                local found=false
                for existing_ns in "${pattern_namespaces[@]}"; do
                    if [ "$existing_ns" = "$ns" ]; then
                        found=true
                        break
                    fi
                done
                if [ "$found" = false ]; then
                    pattern_namespaces+=("$ns")
                fi
            fi
        fi
    done
    
    # Add pattern hub namespace
    pattern_namespaces+=("${PATTERN_NAME}-hub")
    
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
                
                # Check for stuck ArgoCD applications with finalizers
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
                
                # Check for stuck pods
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
    
    local pattern_namespace="${COMPONENTS[pattern-cr_namespace]:-openshift-operators}"
    local pattern_count=$(oc get pattern "$PATTERN_NAME" -n "$pattern_namespace" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$pattern_count" = "0" ]; then
        print_success "Pattern CR already deleted"
        return 0
    fi
    
    print_info "Attempting graceful Pattern CR deletion (non-blocking)..."
    timeout 30s oc delete pattern "$PATTERN_NAME" -n "$pattern_namespace" --wait=false >/dev/null 2>&1 || true
    print_info "Pattern CR delete command issued (non-blocking)"
    
    # Wait for graceful deletion with countdown
    local elapsed=0
    local max_wait=60
    print_info "Waiting up to $max_wait seconds for Pattern CR deletion..."
    while [ $elapsed -lt $max_wait ]; do
        local remaining=$(oc get pattern "$PATTERN_NAME" -n "$pattern_namespace" --no-headers 2>/dev/null | wc -l | tr -d ' ')
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
    oc patch pattern "$PATTERN_NAME" -n "$pattern_namespace" --type='merge' -p='{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    
    # Verify final deletion
    sleep 5
    local final_count=$(oc get pattern "$PATTERN_NAME" -n "$pattern_namespace" --no-headers 2>/dev/null | wc -l | tr -d ' ')
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
    
    local pattern_namespace="${COMPONENTS[pattern-cr_namespace]:-openshift-operators}"
    local pattern_count=$(oc get pattern "$PATTERN_NAME" -n "$pattern_namespace" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    local apps_count=$(oc get applications.argoproj.io -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    # Use config for namespace checking
    local namespace_pattern=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "uninstall.cleanup_patterns.namespaces" "(vault|keycloak|cert-manager|zero-trust|external-secrets)")
    local namespaces_count=$(oc get ns 2>/dev/null | grep -E "$namespace_pattern" | wc -l | tr -d ' ')
    
    local pods_count=0
    
    # Count remaining pods in all component namespaces
    for comp_id in "${!COMPONENTS[@]}"; do
                 if [[ "$comp_id" != *_* ]]; then
             local ns="${COMPONENTS[${comp_id}_namespace]}"
             if [ -n "$ns" ]; then
                 local ns_pods=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
                 pods_count=$((pods_count + ns_pods))
                 
                 # Report stuck resources for debugging
                 if [ "$ns_pods" -gt 0 ]; then
                     print_warning "Namespace $ns still has $ns_pods pods remaining"
                 fi
             fi
         fi
    done
    
    # Also check pattern hub namespace
    local hub_ns="${PATTERN_NAME}-hub"
    local hub_pods=$(oc get pods -n "$hub_ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    pods_count=$((pods_count + hub_pods))
    if [ "$hub_pods" -gt 0 ]; then
        print_warning "Namespace $hub_ns still has $hub_pods pods remaining"
    fi
    
    local subscription_pattern=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "uninstall.cleanup_patterns.subscriptions" "(cert-manager|rhbk|compliance|zero-trust)")
    local subscriptions_count=$(oc get subscriptions -A --no-headers 2>/dev/null | grep -E "$subscription_pattern" | wc -l | tr -d ' ')
    
    local csv_pattern=$(parse_yaml_value "$PATTERN_CONFIG_FILE" "uninstall.cleanup_patterns.csvs" "(cert-manager|keycloak|rhbk|compliance|zero-trust)")
    local csvs_count=$(oc get csv -A --no-headers 2>/dev/null | grep -E "$csv_pattern" | wc -l | tr -d ' ')
    
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

# =============================================================================
# MAIN UNINSTALL FUNCTION
# =============================================================================

# Main uninstall function
main() {
    local dry_run=false
    
    # Check for dry-run flag
    if [[ "$1" == "--dry-run" ]]; then
        echo "DRY RUN MODE - No actual cleanup will occur"
        dry_run=true
        shift
    fi
    
    local pattern_name="$1"
    
    if [ -z "$pattern_name" ]; then
        print_error "Usage: $0 [--dry-run] <pattern-name>"
        print_info "Example: $0 layered-zero-trust"
        print_info "         $0 --dry-run layered-zero-trust"
        exit 1
    fi
    
    PATTERN_NAME="$pattern_name"
    
    # Initialize the pattern library
    if ! init_pattern_lib; then
        print_error "Failed to initialize pattern library"
        exit 1
    fi
    
    # Check if anything needs to be cleaned up
    if ! check_uninstall_state "$pattern_name"; then
        exit 0
    fi
    
    # Show what will be removed
    print_component_tables "uninstall"
    
    # Skip confirmation in dry-run mode
    if [ "$dry_run" = true ]; then
        echo ""
        echo "✓ DRY RUN: Skipping confirmation and actual cleanup"
        echo "✓ Uninstall configuration loaded successfully - cleanup plan ready!"
        exit 0
    fi
    
    # Ask for confirmation
    ask_confirmation "uninstall" "$pattern_name"
    
    print_header "STARTING COMPLETE PATTERN CLEANUP v3.8 (COMPLETE-ARGOCD-AWARE)"
    print_info "Using ArgoCD applications cleanup (including main app), then reverse-order cleanup!"
    
    # Execute cleanup steps in order from config
    cleanup_argocd_applications
    cleanup_gitops_operator
    cleanup_other_operators
    cleanup_patterns_operator
    cleanup_namespaces
    cleanup_pattern_cr
    
    # Final verification
    final_verification
    local exit_code=$?
    
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
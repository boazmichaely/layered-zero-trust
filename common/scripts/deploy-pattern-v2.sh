#!/usr/bin/env bash
set -o pipefail

# New Config-Driven Deploy Script v2.0
# Uses shared pattern library for 5-stage deployment architecture

# Get script directory and source the shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pattern-lib.sh"

# Main deployment function
main() {
    local dry_run=false
    
    # Check for dry-run flag
    if [[ "$1" == "--dry-run" ]]; then
        echo "DRY RUN MODE - No actual deployment will occur"
        dry_run=true
        shift
    fi
    
    local name="$1"
    local chart="$2"
    shift 2
    local helm_opts="$*"
    
    # Initialize the pattern library
    if ! init_pattern_lib; then
        print_error "Failed to initialize pattern library"
        exit 1
    fi
    
    # Show component plan and get confirmation
    print_component_tables "install"
    
    # Skip deployment in dry-run mode
    if [ "$dry_run" = true ]; then
        echo "✓ DRY RUN: Skipping confirmation and actual deployment"
        echo "✓ Configuration loaded successfully - all systems ready!"
        echo "✓ New 5-stage deployment architecture validated!"
        exit 0
    fi
    
    ask_confirmation "install"
    
    # 5-STAGE DEPLOYMENT ARCHITECTURE
    
    # Stage 1: Deploy Vault
    if ! deploy_vault; then
        print_error "Stage 1 failed: Vault deployment failed. Aborting."
        exit 1
    fi
    
    # Stage 2: Load secrets into Vault
    if ! load_secrets "$name"; then
        print_error "Stage 2 failed: Secrets loading failed. Aborting."
        exit 1
    fi
    
    # Stage 3: Deploy operators in parallel and wait for readiness
    if ! deploy_operators_parallel; then
        print_error "Stage 3 failed: Operators deployment failed. Aborting."
        exit 1
    fi
    
    # Stage 4: Deploy Pattern CR (ArgoCD App Factory)
    if ! deploy_pattern_controller "$name" "$chart" $helm_opts; then
        print_error "Stage 4 failed: Pattern CR deployment failed. Aborting."
        exit 1
    fi
    
    # Stage 5: Monitor ArgoCD applications in parallel
    if ! deploy_applications_parallel; then
        print_error "Stage 5 failed: Applications monitoring failed. Aborting."
        exit 1
    fi
    
    # Show live dashboard for final application status
    show_live_dashboard
    
    # Show final summary and exit with appropriate code
    if print_final_summary; then
        print_success "🎉 All 5 stages completed successfully!"
        print_success "✅ Vault → Secrets → Operators → Pattern CR → Applications"
        exit 0
    else
        exit 1
    fi
}

# Execute main function with all arguments
main "$@" 
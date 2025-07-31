#!/usr/bin/env bash
set -o pipefail

# New Config-Driven Deploy Script v2.0
# Uses shared pattern library for 5-stage deployment architecture with comprehensive logging

# Get script directory and source the shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pattern-ux-lib.sh"

# Main deployment function
main() {
    local dry_run=false
    
    # Check for dry-run flag
    if [[ "$1" == "--dry-run" ]]; then
        echo "🧪 DRY RUN MODE - No actual deployment will occur"
        dry_run=true
        shift
    fi
    
    local name="$1"
    local chart="$2"
    shift 2
    local helm_opts="$*"
    
    # Initialize the pattern library (includes discovery and deployment logging)
    if ! init_pattern_lib; then
        print_error "Failed to initialize pattern library"
        exit 1
    fi
    
    # Show log file paths prominently for live runs
    if [ "$dry_run" = false ]; then
        echo ""
        print_info "📋 LIVE DEPLOYMENT LOGGING:"
        echo "  📊 Discovery log: $DISCOVERY_LOG"
        echo "  🚀 Deployment log: $DEPLOYMENT_LOG"
        echo "  ⚠️  Monitor these files during deployment for real-time progress"
        echo ""
    fi
    
    # Show component plan and get confirmation
    print_component_tables "install"
    
    # Handle dry-run completion
    if [ "$dry_run" = true ]; then
        echo ""
        echo "✓ DRY RUN: Skipping confirmation and actual deployment"
        echo "✓ Configuration loaded successfully - all systems ready!"
        echo ""
        print_info "📋 DRY RUN LOG FILES:"
        echo "  📊 Discovery log: $DISCOVERY_LOG"
        echo "  🚀 Deployment log: $DEPLOYMENT_LOG"
        exit 0
    fi
    
    ask_confirmation "install"
    
    # 5-STAGE DEPLOYMENT ARCHITECTURE WITH LOGGING
    
    # Stage 1: Deploy Vault
    if ! deploy_vault; then
        generate_deployment_summary "Stage 1: Vault deployment"
        print_error "Stage 1 failed: Vault deployment failed. Aborting."
        exit 1
    fi
    
    # Stage 2: Load secrets into Vault
    if ! load_secrets "$name"; then
        generate_deployment_summary "Stage 2: Secrets loading"
        print_error "Stage 2 failed: Secrets loading failed. Aborting."
        exit 1
    fi
    
    # Stage 3: Deploy operators in parallel and wait for readiness
    if ! deploy_operators_parallel; then
        generate_deployment_summary "Stage 3: Operators deployment"
        print_error "Stage 3 failed: Operators deployment failed. Aborting."
        exit 1
    fi
    
    # Stage 4: Deploy Pattern CR (ArgoCD App Factory)
    if ! deploy_pattern_controller "$name" "$chart" $helm_opts; then
        generate_deployment_summary "Stage 4: Pattern CR deployment"
        print_error "Stage 4 failed: Pattern CR deployment failed. Aborting."
        exit 1
    fi
    
    # Stage 5: Monitor ArgoCD applications in parallel
    if ! deploy_applications_parallel; then
        generate_deployment_summary "Stage 5: Applications monitoring"
        print_error "Stage 5 failed: Applications monitoring failed. Aborting."
        exit 1
    fi
    
    # Show live dashboard for final application status
    show_live_dashboard
    
    # Show final summary and exit with appropriate code
    if print_final_summary; then
        generate_deployment_summary "SUCCESS" "✅ 5 operators deployed\n✅ 4 applications synced"
        print_success "🎉 All 5 stages completed successfully!"
        print_success "✅ Vault → Secrets → Operators → Pattern CR → Applications"
        exit 0
    else
        generate_deployment_summary "FAILED" "❌ Some components failed to deploy"
        exit 1
    fi
}

# Execute main function with all arguments
main "$@" 
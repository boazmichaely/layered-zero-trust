#!/usr/local/bin/bash
set -o pipefail

# New Config-Driven Deploy Script v2.0
# Uses shared pattern library for configuration-driven pattern deployment

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
    
    # Skip confirmation in dry-run mode
    if [ "$dry_run" = true ]; then
        echo "✓ DRY RUN: Skipping confirmation and actual deployment"
        echo "✓ Configuration loaded successfully - all systems ready!"
        exit 0
    fi
    
    ask_confirmation "install"
    
    # Deploy core pattern infrastructure
    if ! deploy_core_pattern "$name" "$chart" $helm_opts; then
        print_error "Core pattern deployment failed. Aborting."
        exit 1
    fi
    
    # Load secrets BEFORE starting application monitoring
    load_secrets "$name"
    
    # Start all background monitors
    start_all_monitors
    
    # Show live dashboard
    show_live_dashboard
    
    # Show final summary and exit with appropriate code
    if print_final_summary; then
        exit 0
    else
        exit 1
    fi
}

# Execute main function with all arguments
main "$@" 
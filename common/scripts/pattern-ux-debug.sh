#!/usr/local/bin/bash

# Pattern UX Debug Utility
# Tests the pattern-ux-lib.sh functions in isolation

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m'

print_debug() {
    echo -e "${BOLD}${CYAN}[DEBUG] $1${NC}"
}

print_success() {
    echo -e "${BOLD}${GREEN}[SUCCESS] $1${NC}"
}

print_error() {
    echo -e "${BOLD}${RED}[ERROR] $1${NC}"
}

print_warning() {
    echo -e "${BOLD}${YELLOW}[WARNING] $1${NC}"
}

# Get script directory and source the shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_debug "Testing config loading step by step..."

# Test 1: Check if config files exist
print_debug "Step 1: Check config file existence"
if [ -f "common/pattern-config.yaml" ]; then
    print_success "Found pattern-config.yaml"
    echo "  Size: $(wc -l < common/pattern-config.yaml) lines"
else
    print_error "Missing common/pattern-config.yaml"
    exit 1
fi

if [ -f "common/pattern-metadata.yaml" ]; then
    print_success "Found pattern-metadata.yaml"
    echo "  Size: $(wc -l < common/pattern-metadata.yaml) lines"
else
    print_error "Missing common/pattern-metadata.yaml"
    exit 1
fi

# Test 2: Check if library can be sourced
print_debug "Step 2: Source pattern library"
if source "$SCRIPT_DIR/pattern-ux-lib.sh"; then
    print_success "Pattern library sourced successfully"
else
    print_error "Failed to source pattern library"
    exit 1
fi

# Test 3: Test basic config parsing
print_debug "Step 3: Test basic config parsing"
pattern_name=$(parse_yaml_value "common/pattern-config.yaml" "pattern.name" "NOT_FOUND")
pattern_display_name=$(parse_yaml_value "common/pattern-config.yaml" "pattern.display_name" "NOT_FOUND")

echo "  Pattern name: '$pattern_name'"
echo "  Display name: '$pattern_display_name'"

if [ "$pattern_name" = "NOT_FOUND" ] || [ "$pattern_display_name" = "NOT_FOUND" ]; then
    print_error "Basic config parsing failed"
    exit 1
else
    print_success "Basic config parsing works"
fi

# Test 4: Test component loading
print_debug "Step 4: Test component loading"
if load_pattern_config; then
    print_success "Pattern config loaded"
    echo "  Pattern name: ${PATTERN_CONFIG[name]}"
    echo "  Display name: ${PATTERN_CONFIG[display_name]}"
    echo "  Column widths: ${PATTERN_CONFIG[col_width_name]}/${PATTERN_CONFIG[col_width_namespace]}/${PATTERN_CONFIG[col_width_version]}"
else
    print_error "Failed to load pattern config"
    exit 1
fi

# Test 5: Test component discovery
echo "[DEBUG] Step 5: Test component discovery"
# Test component loading
if ! load_components; then
    echo "[ERROR] Failed to load components"
    exit 1
fi

echo "✓ SUCCESS: Components loaded successfully"
echo "  Discovered components:"

# Check some specific components
test_components=("vault-app" "gitops-operator" "keycloak-app" "pattern-cr")

for comp_id in "${test_components[@]}"; do
    if [ -n "${COMPONENTS[$comp_id]:-}" ]; then
        category="${COMPONENTS[$comp_id]}"
        name="${COMPONENTS[${comp_id}_name]:-[NOT_FOUND]}"
        namespace="${COMPONENTS[${comp_id}_namespace]:-[NOT_FOUND]}"
        monitor_type="${COMPONENTS[${comp_id}_monitor_type]:-[NOT_FOUND]}"
        
        echo "    $comp_id ($category):"
        echo "      Name: '$name'"
        echo "      Namespace: '$namespace'"
        echo "      Monitor: '$monitor_type'"
    else
        echo "    $comp_id: NOT FOUND"
    fi
done

echo
echo "[DEBUG] Step 6: Test version discovery"
# Test version discovery for a few components
version_test_result=$(get_component_version "vault-app")
echo "  vault-app version: '$version_test_result'"

version_test_result=$(get_component_version "gitops-operator")
echo "  gitops-operator version: '$version_test_result'"

echo "✓ SUCCESS: All configuration tests passed!"

# Test 7: Test category table generation (dry run)
print_debug "Step 7: Test table generation (dry run)"
echo "Testing table generation..."

# Initialize monitoring for testing
init_monitoring

# Try to print component tables
print_component_tables "install"

print_success "🎉 All config loading tests passed!"
print_debug "The configuration system appears to be working correctly."
print_warning "This doesn't test actual deployment - just config loading and parsing."

# Show full component dump for debugging
print_debug "Full component configuration dump:"
echo "=================================="
for key in "${!COMPONENTS[@]}"; do
    echo "$key=${COMPONENTS[$key]}"
done | sort 
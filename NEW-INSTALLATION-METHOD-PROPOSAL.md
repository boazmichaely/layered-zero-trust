# Config-Driven Pattern Installation  Prototype 

## Overview

This is a prototype for an ineractive method to install (and uninstall) the ZT pattern in a way that is hopefully extendable to other patterns. The main benefits of the interactive method are:
1. User know what is about to get installed, with sufficient detail , so they understand the footprint (namespaces, list of operators and operands with versions, etc)
2. The installation is monitored with live progress so users know what it happening and can address any failures

The proposed method is config-driven with YAML configuration files. It includes component discovery from the underlying helm charts and Make scripts.  Currently this discovery is  limited due to lack of sufficient info from those components and could be made better with a small effort to standardize the information provided by pattern developers, for example using `make show` 


## 📁 File Structure and Purpose

### Core Files

| File | Purpose | Size | What It Does |
|------|---------|------|--------------|
| `pattern-config.yaml` | Component definitions | ~260 lines | Defines all components, their discovery methods, namespaces, and monitoring types |
| `pattern-metadata.yaml` | User-facing text | ~170 lines | Contains all headers, descriptions, and display formatting |
| `pattern-lib.sh` | Shared function library | ~1000 lines | All deployment, monitoring, and cleanup logic |
| `deploy-pattern-v2.sh` | Deploy script | ~52 lines | Thin wrapper that orchestrates deployment |
| `uninstall-pattern-v2.sh` | Uninstall script | ~550 lines | Orchestrates safe cleanup with system protections |

### Supporting Files

| File | Purpose |
|------|---------|
| `debug-pattern-config.sh` | Configuration validation and testing |
| `safety-check.sh` | Verify system namespace protections |
| `SAFETY-CHECKLIST.md` | Safety procedures and guidelines |

---

## 🔄 Main Workflows

### Installation Workflow

```
1. Load Configuration
   ├── Parse pattern-config.yaml → discover all components
   ├── Parse pattern-metadata.yaml → load display text
   └── Initialize monitoring directory

2. Display Plan
   ├── Show component tables by category (Infrastructure/Operators/Applications)
   ├── Display versions discovered from various sources
   └── Get user confirmation

3. Deploy Core Infrastructure
   ├── Deploy Pattern CR via helm
   ├── Wait for Patterns Operator to appear
   └── Load secrets before applications start

4. Start Parallel Monitoring
   ├── Launch background monitors for each component
   ├── Monitor subscriptions (for operators)
   ├── Monitor ArgoCD applications (for apps)
   └── Show live dashboard with real-time updates

5. Final Summary
   ├── Report success/failure for each component
   ├── Show total deployment time
   └── Exit with appropriate code
```

### Uninstall Workflow

```
1. Safety Pre-Flight Check
   ├── Verify system namespace protections
   ├── Display current cluster user and version
   └── Show exactly what will be cleaned vs preserved

2. Resource Discovery
   ├── Scan for Pattern CR, ArgoCD apps, operator subscriptions
   ├── Count running pods, namespaces, and CSVs
   └── Display current pattern footprint

3. Reverse-Order Cleanup
   ├── Delete ArgoCD applications (children before parent)
   ├── Remove GitOps operator
   ├── Clean up pattern operators and subscriptions
   ├── Delete pattern namespaces (NEVER system namespaces)
   ├── Clean resources from system namespaces (preserve namespace)
   └── Remove Pattern CR last

4. Stuck Resource Handling
   ├── Detect stuck finalizers
   ├── Force cleanup of unresponsive pods
   └── Handle ArgoCD server finalizer issues
```

---

## 🔍 Discovery Mechanisms

### What We Discover and Where

| Component Info | Discovery Source | Example |
|----------------|------------------|---------|
| **Component List** | `pattern-config.yaml` | All operators, apps, infrastructure |
| **Version Information** | Multiple sources (see below) | Chart versions, operator channels |
| **Namespaces** | Component configuration | Where each component lives |
| **Monitoring Type** | Component configuration | Subscription vs ArgoCD monitoring |
| **Display Text** | `pattern-metadata.yaml` | Table headers, descriptions |

### Version Discovery Sources

| Source Type | What It Provides | Command/Method | Limitations |
|-------------|------------------|----------------|-------------|
| **`values-global.yaml`** | Pattern CR version | `yq '.clusterGroupChartVersion'` | ✅ Works well |
| **`values-hub.yaml`** | App chart versions | `yq '.vault.chartVersion'` | ✅ Works well |
| **`make show`** | Operator channels | `make show \| grep channel` | ⚠️ **NEEDS IMPROVEMENT** |
| **Local charts** | Chart metadata | Direct chart inspection | ✅ Works well |

### Discovery Problems We Found

#### 1. **`make show` Limitations** ⚠️
```bash
# Current state - unreliable output
make show | grep "gitops.channel"
# Sometimes works, sometimes doesn't, format inconsistent

# What we need
make show-channels    # Dedicated command for operator channels
make show-versions    # Dedicated command for component versions
```

#### 2. **Inconsistent Version Sources** ⚠️
- Some components in `values-global.yaml`
- Some in `values-hub.yaml` 
- Some require `make show` parsing
- No standardized pattern for version discovery

#### 3. **ArgoCD App Detection** ⚠️
```bash
# Current - manual inspection needed
oc get applications.argoproj.io -A

# What we need
# Better way to discover which ArgoCD apps belong to a pattern
# Pattern labels or annotations on ArgoCD applications
```

---

## 🎯 Key Innovation: Config-Driven Component Discovery

### Before (deploy-pattern.sh approach):
```bash
# Hardcoded in script
OPERATORS=("cert-manager" "compliance" "keycloak")
APPLICATIONS=("vault" "keycloak-app" "cert-manager-app")
```

### After (our approach):
```yaml
# pattern-config.yaml
categories:
  operators:
    components:
      - id: "cert-manager-op"
        name: "Cert Manager Operator"
        namespace: "cert-manager-operator"
        version_source:
          type: "values-hub"
          key: "cert-manager.channel"
        monitor_type: "subscription"
```

### Benefits:
- ✅ **Add new components**: Edit YAML file, no code changes
- ✅ **Consistent discovery**: Same logic for all patterns
- ✅ **Version flexibility**: Multiple discovery methods per component
- ✅ **Self-documenting**: Configuration shows what gets installed

---

## 🔧 Areas for Improvement

### 1. **Enhanced `make` Commands** 
**Current Problem**: `make show` output is unreliable for automated parsing

**Proposed Solutions**:
```bash
make show-pattern-info     # Structured output for pattern metadata
make show-component-versions  # All component versions in parseable format
make show-operator-channels   # All operator channels
make show-argocd-apps        # All ArgoCD applications for this pattern
```

### 2. **Standardized Version Discovery**
**Current Problem**: Version information scattered across multiple files

**Proposed Solutions**:
- Standardize on single version source file
- Add version metadata to pattern-config.yaml itself
- Create pattern-versions.yaml with all component versions

### 3. **Pattern Component Labeling**
**Current Problem**: Hard to identify which resources belong to a pattern

**Proposed Solutions**:
```yaml
# Add to all pattern resources
metadata:
  labels:
    pattern.openshift.io/name: "layered-zero-trust"
    pattern.openshift.io/component: "vault"
    pattern.openshift.io/category: "application"
```

### 4. **Improved ArgoCD Integration**
**Current Problem**: Manual discovery of ArgoCD applications

**Proposed Solutions**:
- Pattern-specific ArgoCD application labels
- Structured metadata in ArgoCD app definitions
- Better parent-child relationship tracking

---

## 💡 Benefits of This Approach

### For Pattern Authors:
- **No hardcoded component lists** - everything in configuration
- **Easy component addition** - edit YAML, no bash scripting
- **Consistent UX** - same beautiful tables and workflow across patterns
- **Built-in safety** - system namespace protection, dry-run modes

### for Pattern Users:
- **Professional experience** - clear progress, beautiful output
- **Safety first** - comprehensive warnings and protections
- **Predictable behavior** - same workflow across all patterns

### For Validated Pattern Team:
- **Maintainable codebase** - single library for all patterns
- **Rapid pattern development** - copy config files, customize components
- **Quality assurance** - consistent error handling and safety measures

---

## 🧪 Testing and Validation

### Built-in Testing:
```bash
# Validate configuration without deployment
./debug-pattern-config.sh

# Verify safety mechanisms
./safety-check.sh layered-zero-trust

# Test full workflow safely
./deploy-pattern-v2.sh --dry-run layered-zero-trust common/install-site.yaml
./uninstall-pattern-v2.sh --dry-run layered-zero-trust
```

### What This Tests:
- Configuration parsing and component discovery
- Version discovery from all sources
- Table generation and formatting
- System namespace protection
- Complete workflow without cluster impact

---

## 🚀 Implementation Recommendations

### Phase 1: Core Infrastructure
1. **Enhance `make show`** - Create structured output commands
2. **Standardize version sources** - Agree on single source of truth
3. **Add pattern labeling** - Label all pattern resources consistently

### Phase 2: Pattern Integration
1. **Create template configs** - Standard pattern-config.yaml templates
2. **Build component library** - Common operators and applications
3. **Test with pilot patterns** - Validate approach with 2-3 patterns

### Phase 3: Team Adoption
1. **Create development guidelines** - How to build config-driven patterns
2. **Training and documentation** - Team knowledge transfer
3. **Establish as standard** - Default approach for new patterns

---

## 🔍 Questions for Discussion

1. **Version Discovery**: What's the best single source for component versions?
2. **`make` Enhancement**: Which additional make commands would be most valuable?
3. **Resource Labeling**: Should we standardize pattern resource labels?
4. **ArgoCD Integration**: How can we better track pattern-specific ArgoCD apps?
5. **Configuration Format**: Any improvements to the YAML structure?

---

## 🎯 Call to Action

This config-driven approach represents a **significant improvement** in pattern management:

- **✅ Eliminates hardcoded values** - Everything configurable
- **✅ Provides consistent UX** - Same quality across all patterns
- **✅ Includes comprehensive safety** - System protection built-in
- **✅ Enables rapid development** - Add components without coding

**We recommend adopting this as the standard method for pattern installation and cleanup.**

The foundation is solid - with the improvements outlined above, this becomes a **powerful, maintainable system** for the entire Validated Patterns ecosystem. 
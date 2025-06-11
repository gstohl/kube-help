#!/bin/bash

# Containerd Runtime Health Check Script
# This script analyzes containerd runtime health and configuration

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo "======================================"
echo "Containerd Runtime Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

echo "1. Container Runtime Detection"
echo "----------------------------"

# Get nodes and their container runtime
nodes=$(kubectl get nodes -o json)
total_nodes=$(echo "$nodes" | jq '.items | length')

echo "Analyzing container runtime across $total_nodes nodes..."
echo ""

# Count runtime types
declare -A runtime_counts
runtime_versions=()

for i in $(seq 0 $((total_nodes - 1))); do
    node=$(echo "$nodes" | jq ".items[$i]")
    node_name=$(echo "$node" | jq -r '.metadata.name')
    runtime_info=$(echo "$node" | jq -r '.status.nodeInfo.containerRuntimeVersion')
    
    # Parse runtime type and version
    runtime_type=$(echo "$runtime_info" | cut -d: -f1)
    runtime_version=$(echo "$runtime_info" | cut -d: -f2)
    
    # Count runtime types
    ((runtime_counts[$runtime_type]++))
    runtime_versions+=("$node_name:$runtime_type:$runtime_version")
done

# Display runtime distribution
echo "Container Runtime Distribution:"
for runtime in "${!runtime_counts[@]}"; do
    count=${runtime_counts[$runtime]}
    percentage=$((count * 100 / total_nodes))
    echo "  $runtime: $count nodes ($percentage%)"
done

# Check for runtime consistency
if [ ${#runtime_counts[@]} -gt 1 ]; then
    echo -e "${YELLOW}⚠ Warning: Multiple container runtimes detected${NC}"
    echo "  This may cause inconsistent behavior"
fi

echo ""
echo "2. Containerd Version Analysis"
echo "----------------------------"

# Focus on containerd nodes
containerd_nodes=0
declare -A containerd_versions

for version_info in "${runtime_versions[@]}"; do
    IFS=':' read -r node runtime version <<< "$version_info"
    
    if [[ "$runtime" == "containerd" ]]; then
        ((containerd_nodes++))
        ((containerd_versions[$version]++))
        
        # Check version compatibility
        major_version=$(echo "$version" | cut -d. -f1)
        minor_version=$(echo "$version" | cut -d. -f2)
        
        echo "Node: $node"
        echo "  Runtime: $runtime"
        echo "  Version: $version"
        
        # Version recommendations
        if [[ "$major_version" -eq 1 ]]; then
            if [[ "$minor_version" -lt 6 ]]; then
                echo -e "  ${YELLOW}⚠ Version $version is outdated. Consider upgrading to 1.6.x or later${NC}"
            elif [[ "$minor_version" -eq 6 ]] || [[ "$minor_version" -eq 7 ]]; then
                echo -e "  ${GREEN}✓ Version $version is current and supported${NC}"
            fi
        else
            echo -e "  ${BLUE}ℹ Non-standard version detected${NC}"
        fi
        echo ""
    fi
done

if [ "$containerd_nodes" -eq 0 ]; then
    echo -e "${YELLOW}No containerd runtime nodes found${NC}"
    echo "Found runtimes: ${!runtime_counts[@]}"
    exit 0
fi

# Check version consistency
if [ ${#containerd_versions[@]} -gt 1 ]; then
    echo -e "${YELLOW}⚠ Multiple containerd versions detected:${NC}"
    for version in "${!containerd_versions[@]}"; do
        echo "  Version $version: ${containerd_versions[$version]} nodes"
    done
    echo "  Consider standardizing on a single version"
fi

echo ""
echo "3. Containerd Configuration Check"
echo "-------------------------------"

# Check for containerd config on nodes
echo "Checking containerd configuration..."

# We'll check the first containerd node for detailed config
first_containerd_node=""
for version_info in "${runtime_versions[@]}"; do
    IFS=':' read -r node runtime version <<< "$version_info"
    if [[ "$runtime" == "containerd" ]]; then
        first_containerd_node="$node"
        break
    fi
done

if [ -n "$first_containerd_node" ]; then
    echo "Checking configuration on node: $first_containerd_node"
    
    # Try to get containerd config through a debug pod
    echo ""
    echo "Attempting to analyze containerd configuration..."
    
    # Check if we can access node filesystem
    if kubectl get pods --all-namespaces -o wide | grep -q "$first_containerd_node.*Running"; then
        echo -e "${GREEN}✓ Node is running pods${NC}"
    fi
    
    # Check for common containerd issues in events
    containerd_events=$(kubectl get events --all-namespaces --field-selector reason=FailedCreatePodSandBox -o json | jq '.items[] | select(.message | contains("containerd"))')
    event_count=$(echo "$containerd_events" | jq -s 'length')
    
    if [ "$event_count" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}⚠ Found $event_count containerd-related error events${NC}"
        echo "Recent containerd errors:"
        echo "$containerd_events" | jq -s -r '.[-5:] | .[] | "\(.lastTimestamp): \(.message)"'
    else
        echo -e "${GREEN}✓ No recent containerd error events${NC}"
    fi
fi

echo ""
echo "4. Container Runtime Resource Usage"
echo "---------------------------------"

# Check for high-level runtime metrics
echo "Checking runtime resource consumption..."

# Look for containerd/runtime pods in system namespaces
runtime_pods=$(kubectl get pods --all-namespaces -o json | jq '.items[] | select(.metadata.name | contains("containerd") or contains("runtime"))')
runtime_pod_count=$(echo "$runtime_pods" | jq -s 'length')

if [ "$runtime_pod_count" -gt 0 ]; then
    echo "Found $runtime_pod_count runtime-related pods"
    
    # Check if metrics are available
    if kubectl top pods --all-namespaces &> /dev/null; then
        echo ""
        echo "Runtime pod resource usage:"
        kubectl top pods --all-namespaces 2>/dev/null | grep -E "(containerd|runtime)" | head -10 || echo "  No runtime pods found in top output"
    fi
else
    echo "No dedicated runtime pods found (runtime may be running as system service)"
fi

echo ""
echo "5. Image Pull Performance Analysis"
echo "--------------------------------"

# Analyze image pull errors and performance
echo "Checking for image pull issues..."

# Get recent image pull errors
pull_errors=$(kubectl get events --all-namespaces --field-selector reason=Failed -o json | jq '.items[] | select(.message | contains("pull") or contains("Pull"))')
pull_error_count=$(echo "$pull_errors" | jq -s 'length')

if [ "$pull_error_count" -gt 0 ]; then
    echo -e "${YELLOW}⚠ Found $pull_error_count image pull errors${NC}"
    
    # Categorize errors
    echo ""
    echo "Error categories:"
    
    # Count different error types
    not_found=$(echo "$pull_errors" | jq -s '[.[] | select(.message | contains("not found"))] | length')
    auth_errors=$(echo "$pull_errors" | jq -s '[.[] | select(.message | contains("unauthorized") or contains("forbidden"))] | length')
    network_errors=$(echo "$pull_errors" | jq -s '[.[] | select(.message | contains("timeout") or contains("connection"))] | length')
    
    [ "$not_found" -gt 0 ] && echo "  Image not found: $not_found"
    [ "$auth_errors" -gt 0 ] && echo "  Authentication errors: $auth_errors"
    [ "$network_errors" -gt 0 ] && echo "  Network/timeout errors: $network_errors"
    
    echo ""
    echo "Recent pull errors (last 5):"
    echo "$pull_errors" | jq -s -r '.[-5:] | .[] | "\(.lastTimestamp): \(.message)"'
else
    echo -e "${GREEN}✓ No recent image pull errors${NC}"
fi

echo ""
echo "6. Container Runtime Features"
echo "---------------------------"

# Check for advanced features
echo "Checking runtime capabilities..."

# Check if runtime supports required features
features_to_check=(
    "seccomp"
    "apparmor"
    "selinux"
    "cgroup"
)

# Check pod security standards support
if kubectl get pods --all-namespaces -o json | jq -e '.items[0].spec.securityContext' &> /dev/null; then
    echo -e "${GREEN}✓ Security context support detected${NC}"
else
    echo -e "${YELLOW}⚠ Limited security context usage${NC}"
fi

# Check for runtime classes
runtime_classes=$(kubectl get runtimeclasses -o json 2>/dev/null)
rc_count=$(echo "$runtime_classes" | jq '.items | length' 2>/dev/null || echo "0")

if [ "$rc_count" -gt 0 ]; then
    echo -e "${GREEN}✓ RuntimeClasses configured: $rc_count${NC}"
    echo ""
    echo "Available RuntimeClasses:"
    echo "$runtime_classes" | jq -r '.items[] | "  \(.metadata.name): \(.handler)"'
else
    echo "ℹ No RuntimeClasses configured"
fi

echo ""
echo "7. Container Storage Analysis"
echo "---------------------------"

# Check for storage driver and disk usage
echo "Analyzing container storage..."

# Look for disk pressure events
disk_pressure_events=$(kubectl get events --all-namespaces --field-selector reason=NodeHasDiskPressure -o json | jq '.items | length')

if [ "$disk_pressure_events" -gt 0 ]; then
    echo -e "${YELLOW}⚠ Found $disk_pressure_events disk pressure events${NC}"
    echo "  This may indicate container storage issues"
fi

# Check for evicted pods due to disk
evicted_pods=$(kubectl get pods --all-namespaces --field-selector=status.phase=Failed -o json | jq '[.items[] | select(.status.reason == "Evicted")] | length')

if [ "$evicted_pods" -gt 0 ]; then
    echo -e "${YELLOW}⚠ Found $evicted_pods evicted pods${NC}"
    
    # Check eviction reasons
    disk_evictions=$(kubectl get pods --all-namespaces --field-selector=status.phase=Failed -o json | jq '[.items[] | select(.status.reason == "Evicted" and .status.message | contains("disk"))] | length')
    
    if [ "$disk_evictions" -gt 0 ]; then
        echo -e "${RED}  ✗ $disk_evictions pods evicted due to disk pressure${NC}"
    fi
fi

echo ""
echo "8. Container Runtime Compatibility"
echo "--------------------------------"

# Check Kubernetes vs runtime compatibility
echo "Checking Kubernetes and runtime compatibility..."

# Get Kubernetes version
k8s_version=$(kubectl version -o json | jq -r '.serverVersion | "\(.major).\(.minor)"')
echo "Kubernetes version: $k8s_version"

# Compatibility matrix
echo ""
echo "Compatibility Analysis:"

for version_info in "${runtime_versions[@]}"; do
    IFS=':' read -r node runtime version <<< "$version_info"
    
    if [[ "$runtime" == "containerd" ]]; then
        containerd_major=$(echo "$version" | cut -d. -f1)
        containerd_minor=$(echo "$version" | cut -d. -f2)
        
        # Basic compatibility check
        k8s_major=$(echo "$k8s_version" | cut -d. -f1)
        k8s_minor=$(echo "$k8s_version" | cut -d. -f2 | sed 's/[^0-9]//g')
        
        echo "Node $node:"
        echo "  Kubernetes: $k8s_version"
        echo "  Containerd: $version"
        
        # Compatibility recommendations based on k8s version
        if [ "$k8s_minor" -ge 24 ]; then
            if [ "$containerd_minor" -lt 6 ]; then
                echo -e "  ${YELLOW}⚠ Containerd 1.6+ recommended for Kubernetes 1.24+${NC}"
            else
                echo -e "  ${GREEN}✓ Compatible versions${NC}"
            fi
        elif [ "$k8s_minor" -ge 20 ]; then
            if [ "$containerd_minor" -lt 4 ]; then
                echo -e "  ${YELLOW}⚠ Containerd 1.4+ recommended for Kubernetes 1.20+${NC}"
            else
                echo -e "  ${GREEN}✓ Compatible versions${NC}"
            fi
        fi
        echo ""
    fi
done

echo "9. Runtime Health Indicators"
echo "--------------------------"

# Summary health indicators
echo "Health Status Summary:"

health_score=100
issues=0

# Deduct points for issues
if [ ${#runtime_counts[@]} -gt 1 ]; then
    echo -e "${YELLOW}⚠ Multiple runtimes detected${NC}"
    ((health_score-=10))
    ((issues++))
fi

if [ ${#containerd_versions[@]} -gt 1 ]; then
    echo -e "${YELLOW}⚠ Multiple containerd versions${NC}"
    ((health_score-=10))
    ((issues++))
fi

if [ "$pull_error_count" -gt 10 ]; then
    echo -e "${YELLOW}⚠ High number of image pull errors${NC}"
    ((health_score-=15))
    ((issues++))
fi

if [ "$disk_evictions" -gt 0 ]; then
    echo -e "${RED}✗ Pods evicted due to disk pressure${NC}"
    ((health_score-=20))
    ((issues++))
fi

# Overall score
echo ""
echo -n "Runtime Health Score: "
if [ "$health_score" -ge 90 ]; then
    echo -e "${GREEN}$health_score/100${NC}"
elif [ "$health_score" -ge 70 ]; then
    echo -e "${YELLOW}$health_score/100${NC}"
else
    echo -e "${RED}$health_score/100${NC}"
fi

echo ""
echo "10. Recommendations"
echo "-----------------"

recommendations=0

# Version recommendations
for version in "${!containerd_versions[@]}"; do
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)
    
    if [[ "$major" -eq 1 ]] && [[ "$minor" -lt 6 ]]; then
        echo -e "${YELLOW}• Upgrade containerd from $version to 1.6.x or later${NC}"
        ((recommendations++))
    fi
done

# Consistency recommendations
if [ ${#runtime_counts[@]} -gt 1 ]; then
    echo -e "${YELLOW}• Standardize on a single container runtime across all nodes${NC}"
    ((recommendations++))
fi

if [ ${#containerd_versions[@]} -gt 1 ]; then
    echo -e "${YELLOW}• Standardize containerd version across all nodes${NC}"
    ((recommendations++))
fi

# Performance recommendations
if [ "$pull_error_count" -gt 10 ]; then
    echo -e "${BLUE}• Configure image pull secrets and registry mirrors${NC}"
    ((recommendations++))
fi

if [ "$disk_evictions" -gt 0 ]; then
    echo -e "${RED}• Increase node disk space or configure garbage collection${NC}"
    ((recommendations++))
fi

# Feature recommendations
if [ "$rc_count" -eq 0 ]; then
    echo -e "${BLUE}• Consider using RuntimeClasses for workload isolation${NC}"
    ((recommendations++))
fi

if [ "$recommendations" -eq 0 ]; then
    echo -e "${GREEN}✓ Container runtime configuration looks good!${NC}"
fi

echo ""
echo "======================================"
echo "Containerd Runtime Check Complete"
echo ""
echo "Summary:"
echo "- Total nodes: $total_nodes"
echo "- Containerd nodes: $containerd_nodes"
echo "- Runtime types: ${#runtime_counts[@]}"
echo "- Health score: $health_score/100"
echo "- Issues found: $issues"
echo "- Recommendations: $recommendations"
echo "======================================"
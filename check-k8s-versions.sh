#!/bin/bash

# Kubernetes Version Compatibility Check Script
# This script analyzes version compatibility across all Kubernetes components

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
echo "Kubernetes Version Compatibility Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

echo "1. Cluster Version Information"
echo "----------------------------"

# Get server and client versions
echo "Getting version information..."

# Server version
server_version=$(kubectl version -o json | jq -r '.serverVersion')
server_major=$(echo "$server_version" | jq -r '.major')
server_minor=$(echo "$server_version" | jq -r '.minor' | sed 's/[^0-9]//g')
server_git=$(echo "$server_version" | jq -r '.gitVersion')
server_go=$(echo "$server_version" | jq -r '.goVersion')

# Client version
client_version=$(kubectl version -o json | jq -r '.clientVersion')
client_major=$(echo "$client_version" | jq -r '.major')
client_minor=$(echo "$client_version" | jq -r '.minor' | sed 's/[^0-9]//g')
client_git=$(echo "$client_version" | jq -r '.gitVersion')

echo "Kubernetes API Server:"
echo "  Version: $server_git"
echo "  Major: $server_major, Minor: $server_minor"
echo "  Go Version: $server_go"
echo ""

echo "kubectl Client:"
echo "  Version: $client_git"
echo "  Major: $client_major, Minor: $client_minor"

# Check client-server compatibility
version_diff=$((client_minor - server_minor))
echo ""
echo -n "Client-Server Compatibility: "
if [ "$version_diff" -gt 1 ] || [ "$version_diff" -lt -1 ]; then
    echo -e "${YELLOW}⚠ Warning: Version skew detected (difference: $version_diff)${NC}"
    echo "  kubectl should be within one minor version of the API server"
else
    echo -e "${GREEN}✓ Compatible (difference: $version_diff)${NC}"
fi

echo ""
echo "2. Node Component Versions"
echo "------------------------"

# Get node information
nodes=$(kubectl get nodes -o json)
total_nodes=$(echo "$nodes" | jq '.items | length')

echo "Analyzing $total_nodes nodes..."
echo ""

# Track versions
declare -A kubelet_versions
declare -A proxy_versions
declare -A runtime_versions
declare -A os_versions
declare -A kernel_versions

# Analyze each node
for i in $(seq 0 $((total_nodes - 1))); do
    node=$(echo "$nodes" | jq ".items[$i]")
    node_name=$(echo "$node" | jq -r '.metadata.name')
    
    # Get versions
    kubelet_version=$(echo "$node" | jq -r '.status.nodeInfo.kubeletVersion')
    proxy_version=$(echo "$node" | jq -r '.status.nodeInfo.kubeProxyVersion')
    runtime_version=$(echo "$node" | jq -r '.status.nodeInfo.containerRuntimeVersion')
    os_version=$(echo "$node" | jq -r '.status.nodeInfo.osImage')
    kernel_version=$(echo "$node" | jq -r '.status.nodeInfo.kernelVersion')
    
    # Count versions
    ((kubelet_versions[$kubelet_version]++))
    ((proxy_versions[$proxy_version]++))
    ((runtime_versions[$runtime_version]++))
    ((os_versions[$os_version]++))
    ((kernel_versions[$kernel_version]++))
    
    # Display node info
    echo "Node: $node_name"
    echo "  Kubelet: $kubelet_version"
    echo "  Kube-proxy: $proxy_version"
    echo "  Runtime: $runtime_version"
    echo "  OS: $os_version"
    echo "  Kernel: $kernel_version"
    
    # Check kubelet vs API server compatibility
    kubelet_minor=$(echo "$kubelet_version" | grep -oE 'v[0-9]+\.[0-9]+' | cut -d. -f2)
    kubelet_diff=$((server_minor - kubelet_minor))
    
    if [ "$kubelet_diff" -gt 2 ] || [ "$kubelet_diff" -lt -2 ]; then
        echo -e "  ${RED}✗ Kubelet version skew too large (difference: $kubelet_diff)${NC}"
    elif [ "$kubelet_diff" -ne 0 ]; then
        echo -e "  ${YELLOW}⚠ Kubelet version differs from API server (difference: $kubelet_diff)${NC}"
    else
        echo -e "  ${GREEN}✓ Kubelet version matches API server${NC}"
    fi
    echo ""
done

echo "3. Version Consistency Analysis"
echo "-----------------------------"

# Check kubelet version consistency
echo "Kubelet Version Distribution:"
if [ ${#kubelet_versions[@]} -eq 1 ]; then
    echo -e "${GREEN}✓ All nodes running same kubelet version${NC}"
else
    echo -e "${YELLOW}⚠ Multiple kubelet versions detected:${NC}"
    for version in "${!kubelet_versions[@]}"; do
        echo "  $version: ${kubelet_versions[$version]} node(s)"
    done
fi

echo ""
echo "Kube-proxy Version Distribution:"
if [ ${#proxy_versions[@]} -eq 1 ]; then
    echo -e "${GREEN}✓ All nodes running same kube-proxy version${NC}"
else
    echo -e "${YELLOW}⚠ Multiple kube-proxy versions detected:${NC}"
    for version in "${!proxy_versions[@]}"; do
        echo "  $version: ${proxy_versions[$version]} node(s)"
    done
fi

echo ""
echo "Container Runtime Distribution:"
for runtime in "${!runtime_versions[@]}"; do
    echo "  $runtime: ${runtime_versions[$runtime]} node(s)"
done

echo ""
echo "4. Control Plane Component Versions"
echo "---------------------------------"

# Check control plane components
echo "Checking control plane components..."

# API Server
api_pods=$(kubectl get pods -n kube-system -l component=kube-apiserver -o json 2>/dev/null)
if [ "$(echo "$api_pods" | jq '.items | length')" -gt 0 ]; then
    api_version=$(echo "$api_pods" | jq -r '.items[0].spec.containers[0].image' | cut -d: -f2)
    echo "API Server: $api_version"
else
    echo "API Server: Using static pods or external"
fi

# Controller Manager
cm_pods=$(kubectl get pods -n kube-system -l component=kube-controller-manager -o json 2>/dev/null)
if [ "$(echo "$cm_pods" | jq '.items | length')" -gt 0 ]; then
    cm_version=$(echo "$cm_pods" | jq -r '.items[0].spec.containers[0].image' | cut -d: -f2)
    echo "Controller Manager: $cm_version"
fi

# Scheduler
sched_pods=$(kubectl get pods -n kube-system -l component=kube-scheduler -o json 2>/dev/null)
if [ "$(echo "$sched_pods" | jq '.items | length')" -gt 0 ]; then
    sched_version=$(echo "$sched_pods" | jq -r '.items[0].spec.containers[0].image' | cut -d: -f2)
    echo "Scheduler: $sched_version"
fi

# etcd
etcd_pods=$(kubectl get pods -n kube-system -l component=etcd -o json 2>/dev/null)
if [ "$(echo "$etcd_pods" | jq '.items | length')" -gt 0 ]; then
    etcd_version=$(echo "$etcd_pods" | jq -r '.items[0].spec.containers[0].image' | cut -d: -f2)
    echo "etcd: $etcd_version"
    
    # Check etcd compatibility
    etcd_major=$(echo "$etcd_version" | cut -d. -f1)
    etcd_minor=$(echo "$etcd_version" | cut -d. -f2)
    
    if [ "$server_minor" -ge 28 ] && [ "$etcd_major" -lt 3 ]; then
        echo -e "  ${YELLOW}⚠ Kubernetes 1.28+ requires etcd 3.x${NC}"
    elif [ "$server_minor" -ge 22 ] && [ "$etcd_major" -eq 3 ] && [ "$etcd_minor" -lt 5 ]; then
        echo -e "  ${YELLOW}⚠ Kubernetes 1.22+ recommends etcd 3.5+${NC}"
    else
        echo -e "  ${GREEN}✓ etcd version compatible${NC}"
    fi
fi

echo ""
echo "5. Critical Component Analysis"
echo "----------------------------"

# CoreDNS version
coredns_deploy=$(kubectl get deployment -n kube-system coredns -o json 2>/dev/null)
if [ -n "$coredns_deploy" ] && [ "$coredns_deploy" != "null" ]; then
    coredns_image=$(echo "$coredns_deploy" | jq -r '.spec.template.spec.containers[0].image')
    coredns_version=$(echo "$coredns_image" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    echo "CoreDNS: $coredns_version"
    
    # Check CoreDNS compatibility with Kubernetes version
    if [ "$server_minor" -ge 28 ] && [[ "$coredns_version" < "1.10" ]]; then
        echo -e "  ${YELLOW}⚠ Kubernetes 1.28+ recommends CoreDNS 1.10+${NC}"
    elif [ "$server_minor" -ge 25 ] && [[ "$coredns_version" < "1.9" ]]; then
        echo -e "  ${YELLOW}⚠ Kubernetes 1.25+ recommends CoreDNS 1.9+${NC}"
    else
        echo -e "  ${GREEN}✓ CoreDNS version appropriate${NC}"
    fi
fi

# CNI Plugin versions
echo ""
echo "CNI Plugin Detection:"
for cni in "calico" "weave" "flannel" "cilium" "canal" "kube-router"; do
    cni_pods=$(kubectl get pods --all-namespaces -o json | jq ".items[] | select(.metadata.name | contains(\"$cni\"))")
    if [ -n "$cni_pods" ] && [ "$cni_pods" != "null" ]; then
        cni_image=$(echo "$cni_pods" | jq -r '.spec.containers[0].image' | head -1)
        cni_version=$(echo "$cni_image" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo "  $cni: $cni_version"
    fi
done

echo ""
echo "6. Feature Gates and API Versions"
echo "--------------------------------"

# Check deprecated APIs
echo "Checking for deprecated API usage..."

# Try to get API server configuration
api_server_pod=$(kubectl get pods -n kube-system -l component=kube-apiserver -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$api_server_pod" ]; then
    # Check for feature gates
    feature_gates=$(kubectl get pod -n kube-system "$api_server_pod" -o yaml | grep -A5 "feature-gates" | grep -v "feature-gates" | head -5 || echo "")
    if [ -n "$feature_gates" ]; then
        echo "Feature gates configured:"
        echo "$feature_gates"
    fi
fi

# Check for deprecated API versions in use
echo ""
echo "Checking for deprecated API usage..."
deprecated_count=0

# Check for deprecated batch/v1beta1
if kubectl get cronjobs.batch --all-namespaces -o json 2>/dev/null | jq -e '.items[] | select(.apiVersion == "batch/v1beta1")' &> /dev/null; then
    echo -e "${YELLOW}⚠ Found CronJobs using deprecated batch/v1beta1 API${NC}"
    ((deprecated_count++))
fi

# Check for deprecated networking.k8s.io/v1beta1
if kubectl get ingresses.networking.k8s.io --all-namespaces -o json 2>/dev/null | jq -e '.items[] | select(.apiVersion == "networking.k8s.io/v1beta1")' &> /dev/null; then
    echo -e "${YELLOW}⚠ Found Ingresses using deprecated networking.k8s.io/v1beta1 API${NC}"
    ((deprecated_count++))
fi

if [ "$deprecated_count" -eq 0 ]; then
    echo -e "${GREEN}✓ No deprecated APIs detected in use${NC}"
fi

echo ""
echo "7. Version Upgrade Path Analysis"
echo "------------------------------"

echo "Current cluster version: $server_git"
echo ""

# Determine upgrade recommendations
current_minor="$server_minor"
latest_stable_minor=29  # Update this based on current K8s releases

if [ "$current_minor" -lt $((latest_stable_minor - 3)) ]; then
    echo -e "${RED}✗ Cluster version is significantly outdated${NC}"
    echo "  Current: 1.$current_minor"
    echo "  Latest stable: 1.$latest_stable_minor"
    echo "  Recommended upgrade path:"
    
    # Show upgrade path
    next_version=$((current_minor + 1))
    while [ "$next_version" -le "$latest_stable_minor" ]; do
        echo "    → 1.$next_version"
        next_version=$((next_version + 1))
    done
elif [ "$current_minor" -lt "$latest_stable_minor" ]; then
    echo -e "${YELLOW}⚠ Newer Kubernetes versions available${NC}"
    echo "  Current: 1.$current_minor"
    echo "  Latest stable: 1.$latest_stable_minor"
else
    echo -e "${GREEN}✓ Running latest stable version${NC}"
fi

echo ""
echo "8. Component Compatibility Matrix"
echo "-------------------------------"

echo "Compatibility Summary:"
echo ""

# Create compatibility matrix
compatibility_issues=0

# Check kubelet versions against API server
echo "Kubelet Compatibility:"
for version in "${!kubelet_versions[@]}"; do
    kubelet_minor=$(echo "$version" | grep -oE 'v[0-9]+\.[0-9]+' | cut -d. -f2)
    diff=$((server_minor - kubelet_minor))
    
    if [ "$diff" -gt 2 ] || [ "$diff" -lt -2 ]; then
        echo -e "  ${RED}✗ $version: Incompatible (skew: $diff)${NC}"
        ((compatibility_issues++))
    elif [ "$diff" -ne 0 ]; then
        echo -e "  ${YELLOW}⚠ $version: Version skew (difference: $diff)${NC}"
    else
        echo -e "  ${GREEN}✓ $version: Compatible${NC}"
    fi
done

# Check critical addons
echo ""
echo "Addon Compatibility:"

# Check metrics-server
metrics_server=$(kubectl get deployment -n kube-system metrics-server -o json 2>/dev/null)
if [ -n "$metrics_server" ] && [ "$metrics_server" != "null" ]; then
    ms_image=$(echo "$metrics_server" | jq -r '.spec.template.spec.containers[0].image')
    ms_version=$(echo "$ms_image" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    echo "  Metrics Server: $ms_version"
fi

echo ""
echo "9. Security Updates Check"
echo "-----------------------"

# Check for known CVEs based on version
echo "Security Advisory Check:"

# Simple CVE check based on version (this is a basic example)
if [ "$server_minor" -lt 24 ]; then
    echo -e "${RED}✗ Multiple CVEs fixed in newer versions${NC}"
    echo "  Consider upgrading to benefit from security patches"
elif [ "$server_minor" -lt 27 ]; then
    echo -e "${YELLOW}⚠ Some security improvements available in newer versions${NC}"
else
    echo -e "${GREEN}✓ Running recent version with latest security patches${NC}"
fi

echo ""
echo "10. Recommendations"
echo "-----------------"

recommendations=0

# Version consistency
if [ ${#kubelet_versions[@]} -gt 1 ]; then
    echo -e "${YELLOW}• Standardize kubelet versions across all nodes${NC}"
    ((recommendations++))
fi

if [ ${#proxy_versions[@]} -gt 1 ]; then
    echo -e "${YELLOW}• Standardize kube-proxy versions across all nodes${NC}"
    ((recommendations++))
fi

# Version skew
if [ "$compatibility_issues" -gt 0 ]; then
    echo -e "${RED}• Fix version compatibility issues${NC}"
    ((recommendations++))
fi

# Upgrade recommendations
if [ "$current_minor" -lt $((latest_stable_minor - 2)) ]; then
    echo -e "${YELLOW}• Plan cluster upgrade to newer Kubernetes version${NC}"
    ((recommendations++))
fi

# Deprecated APIs
if [ "$deprecated_count" -gt 0 ]; then
    echo -e "${YELLOW}• Migrate from deprecated API versions${NC}"
    ((recommendations++))
fi

# Client version
if [ "$version_diff" -gt 1 ] || [ "$version_diff" -lt -1 ]; then
    echo -e "${BLUE}• Update kubectl to match server version${NC}"
    ((recommendations++))
fi

if [ "$recommendations" -eq 0 ]; then
    echo -e "${GREEN}✓ Version configuration looks good!${NC}"
fi

echo ""
echo "======================================"
echo "Version Compatibility Check Complete"
echo ""
echo "Summary:"
echo "- Cluster version: $server_git"
echo "- Node count: $total_nodes"
echo "- Kubelet versions: ${#kubelet_versions[@]}"
echo "- Compatibility issues: $compatibility_issues"
echo "- Deprecated APIs in use: $deprecated_count"
echo "- Recommendations: $recommendations"
echo "======================================"
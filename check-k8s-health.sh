#!/bin/bash

# General Kubernetes Cluster Health Check Script
# This script performs a comprehensive health check of the Kubernetes cluster

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "======================================"
echo "Kubernetes Cluster Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

# Check kubectl connection
echo "Checking cluster connection..."
if ! kubectl cluster-info &> /dev/null; then
    echo -e "${RED}Error: Cannot connect to Kubernetes cluster. Check your kubeconfig.${NC}"
    exit 1
fi

CLUSTER_INFO=$(kubectl cluster-info | head -n 1)
echo -e "${GREEN}✓ Connected to: $CLUSTER_INFO${NC}"
echo ""

echo "1. Cluster Information"
echo "---------------------"
# Get server version
SERVER_VERSION=$(kubectl version -o json | jq -r '.serverVersion | "\(.major).\(.minor) (\(.gitVersion))"')
echo "Server Version: $SERVER_VERSION"

# Get cluster nodes count
NODE_COUNT=$(kubectl get nodes -o json | jq '.items | length')
echo "Total Nodes: $NODE_COUNT"

# Get namespaces count
NS_COUNT=$(kubectl get namespaces -o json | jq '.items | length')
echo "Total Namespaces: $NS_COUNT"
echo ""

echo "2. Node Health Check"
echo "-------------------"
nodes=$(kubectl get nodes -o json)
total_nodes=$(echo "$nodes" | jq '.items | length')
ready_nodes=$(echo "$nodes" | jq '[.items[] | select(.status.conditions[] | select(.type == "Ready" and .status == "True"))] | length')
not_ready_nodes=$(echo "$nodes" | jq '[.items[] | select(.status.conditions[] | select(.type == "Ready" and .status != "True"))] | length')

echo "Total nodes: $total_nodes"
if [ "$ready_nodes" -eq "$total_nodes" ]; then
    echo -e "${GREEN}✓ All nodes are Ready: $ready_nodes/$total_nodes${NC}"
else
    echo -e "${YELLOW}⚠ Ready nodes: $ready_nodes/$total_nodes${NC}"
    if [ "$not_ready_nodes" -gt 0 ]; then
        echo -e "${RED}✗ Not Ready nodes:${NC}"
        kubectl get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type == "Ready" and .status != "True")) | .metadata.name'
    fi
fi

# Check for node pressure conditions
echo ""
echo "Node Conditions:"
memory_pressure=$(echo "$nodes" | jq '[.items[] | select(.status.conditions[] | select(.type == "MemoryPressure" and .status == "True"))] | length')
disk_pressure=$(echo "$nodes" | jq '[.items[] | select(.status.conditions[] | select(.type == "DiskPressure" and .status == "True"))] | length')
pid_pressure=$(echo "$nodes" | jq '[.items[] | select(.status.conditions[] | select(.type == "PIDPressure" and .status == "True"))] | length')

if [ "$memory_pressure" -eq 0 ] && [ "$disk_pressure" -eq 0 ] && [ "$pid_pressure" -eq 0 ]; then
    echo -e "${GREEN}✓ No node pressure conditions detected${NC}"
else
    [ "$memory_pressure" -gt 0 ] && echo -e "${YELLOW}⚠ Nodes with MemoryPressure: $memory_pressure${NC}"
    [ "$disk_pressure" -gt 0 ] && echo -e "${YELLOW}⚠ Nodes with DiskPressure: $disk_pressure${NC}"
    [ "$pid_pressure" -gt 0 ] && echo -e "${YELLOW}⚠ Nodes with PIDPressure: $pid_pressure${NC}"
fi

# Node resource usage
echo ""
echo "Node Resources:"
kubectl top nodes 2>/dev/null || echo -e "${YELLOW}Note: kubectl top not available (metrics-server may not be installed)${NC}"
echo ""

echo "3. Control Plane Components"
echo "--------------------------"
# Check API Server
echo -n "API Server: "
if kubectl get --raw /healthz &> /dev/null; then
    echo -e "${GREEN}✓ Healthy${NC}"
else
    echo -e "${RED}✗ Unhealthy${NC}"
fi

# Check etcd (if accessible)
echo -n "etcd: "
if kubectl get --raw /healthz/etcd 2>/dev/null | grep -q "ok"; then
    echo -e "${GREEN}✓ Healthy${NC}"
else
    echo -e "${YELLOW}⚠ Cannot check (may require additional permissions)${NC}"
fi

# Check controller manager and scheduler
for component in kube-controller-manager kube-scheduler; do
    echo -n "$component: "
    if kubectl get pods -n kube-system -l component=$component -o json | jq -e '.items[0].status.phase == "Running"' &> /dev/null; then
        echo -e "${GREEN}✓ Running${NC}"
    else
        echo -e "${YELLOW}⚠ Not found or not running${NC}"
    fi
done
echo ""

echo "4. System Pods Health"
echo "--------------------"
# Check kube-system namespace
kube_system_pods=$(kubectl get pods -n kube-system -o json)
total_system_pods=$(echo "$kube_system_pods" | jq '.items | length')
running_system_pods=$(echo "$kube_system_pods" | jq '[.items[] | select(.status.phase == "Running")] | length')
failed_system_pods=$(echo "$kube_system_pods" | jq '[.items[] | select(.status.phase == "Failed")] | length')

echo "kube-system namespace:"
echo "Total pods: $total_system_pods"
if [ "$running_system_pods" -eq "$total_system_pods" ]; then
    echo -e "${GREEN}✓ All system pods are Running: $running_system_pods/$total_system_pods${NC}"
else
    echo -e "${YELLOW}⚠ Running pods: $running_system_pods/$total_system_pods${NC}"
    if [ "$failed_system_pods" -gt 0 ]; then
        echo -e "${RED}✗ Failed pods: $failed_system_pods${NC}"
        kubectl get pods -n kube-system --field-selector=status.phase=Failed
    fi
fi

# Check critical components
echo ""
echo "Critical Components:"
for component in coredns kube-proxy; do
    count=$(kubectl get pods -n kube-system -l k8s-app=$component -o json | jq '[.items[] | select(.status.phase == "Running")] | length')
    total=$(kubectl get pods -n kube-system -l k8s-app=$component -o json | jq '.items | length')
    if [ "$total" -gt 0 ]; then
        if [ "$count" -eq "$total" ]; then
            echo -e "${GREEN}✓ $component: $count/$total pods running${NC}"
        else
            echo -e "${YELLOW}⚠ $component: $count/$total pods running${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ $component: Not found${NC}"
    fi
done
echo ""

echo "5. Persistent Volumes"
echo "--------------------"
pvs=$(kubectl get pv -o json)
total_pvs=$(echo "$pvs" | jq '.items | length')
bound_pvs=$(echo "$pvs" | jq '[.items[] | select(.status.phase == "Bound")] | length')
available_pvs=$(echo "$pvs" | jq '[.items[] | select(.status.phase == "Available")] | length')
failed_pvs=$(echo "$pvs" | jq '[.items[] | select(.status.phase == "Failed")] | length')

echo "Total PVs: $total_pvs"
[ "$bound_pvs" -gt 0 ] && echo -e "${GREEN}✓ Bound: $bound_pvs${NC}"
[ "$available_pvs" -gt 0 ] && echo -e "${BLUE}ℹ Available: $available_pvs${NC}"
[ "$failed_pvs" -gt 0 ] && echo -e "${RED}✗ Failed: $failed_pvs${NC}"

# Check PVCs
pvcs=$(kubectl get pvc --all-namespaces -o json)
total_pvcs=$(echo "$pvcs" | jq '.items | length')
bound_pvcs=$(echo "$pvcs" | jq '[.items[] | select(.status.phase == "Bound")] | length')
pending_pvcs=$(echo "$pvcs" | jq '[.items[] | select(.status.phase == "Pending")] | length')

echo ""
echo "Total PVCs: $total_pvcs"
[ "$bound_pvcs" -gt 0 ] && echo -e "${GREEN}✓ Bound: $bound_pvcs${NC}"
if [ "$pending_pvcs" -gt 0 ]; then
    echo -e "${YELLOW}⚠ Pending: $pending_pvcs${NC}"
    echo "Pending PVCs:"
    kubectl get pvc --all-namespaces | grep Pending
fi
echo ""

echo "6. Pod Health Summary"
echo "--------------------"
all_pods=$(kubectl get pods --all-namespaces -o json)
total_pods=$(echo "$all_pods" | jq '.items | length')
running_pods=$(echo "$all_pods" | jq '[.items[] | select(.status.phase == "Running")] | length')
pending_pods=$(echo "$all_pods" | jq '[.items[] | select(.status.phase == "Pending")] | length')
failed_pods=$(echo "$all_pods" | jq '[.items[] | select(.status.phase == "Failed")] | length')
unknown_pods=$(echo "$all_pods" | jq '[.items[] | select(.status.phase == "Unknown")] | length')

echo "Total pods across all namespaces: $total_pods"
echo -e "${GREEN}✓ Running: $running_pods${NC}"
[ "$pending_pods" -gt 0 ] && echo -e "${YELLOW}⚠ Pending: $pending_pods${NC}"
[ "$failed_pods" -gt 0 ] && echo -e "${RED}✗ Failed: $failed_pods${NC}"
[ "$unknown_pods" -gt 0 ] && echo -e "${RED}✗ Unknown: $unknown_pods${NC}"

# Check for pods with high restart counts
echo ""
echo "Pods with high restart counts (>5):"
high_restart_pods=$(echo "$all_pods" | jq -r '.items[] | select(.status.containerStatuses != null) | select(.status.containerStatuses | map(.restartCount) | max > 5) | "\(.metadata.namespace)/\(.metadata.name): \(.status.containerStatuses | map(.restartCount) | max) restarts"')
if [ -n "$high_restart_pods" ]; then
    echo -e "${YELLOW}$high_restart_pods${NC}"
else
    echo -e "${GREEN}✓ No pods with high restart counts${NC}"
fi
echo ""

echo "7. Resource Quotas and Limits"
echo "-----------------------------"
# Check for resource quotas
quotas=$(kubectl get resourcequota --all-namespaces -o json | jq '.items | length')
if [ "$quotas" -gt 0 ]; then
    echo "Resource quotas configured in $quotas namespace(s)"
    kubectl get resourcequota --all-namespaces -o json | jq -r '.items[] | "\(.metadata.namespace): \(.status.used | to_entries | map("\(.key)=\(.value)") | join(", "))"' | head -5
else
    echo "No resource quotas configured"
fi

# Check for limit ranges
limits=$(kubectl get limitrange --all-namespaces -o json | jq '.items | length')
if [ "$limits" -gt 0 ]; then
    echo "Limit ranges configured in $limits namespace(s)"
else
    echo "No limit ranges configured"
fi
echo ""

echo "8. Recent Cluster Events"
echo "-----------------------"
recent_warnings=$(kubectl get events --all-namespaces --field-selector type=Warning -o json | jq '.items | length')
if [ "$recent_warnings" -gt 0 ]; then
    echo -e "${YELLOW}⚠ Found $recent_warnings warning events${NC}"
    echo "Most recent warnings:"
    kubectl get events --all-namespaces --field-selector type=Warning --sort-by='.lastTimestamp' -o json | jq -r '.items | sort_by(.lastTimestamp) | reverse | .[0:5] | .[] | "\(.lastTimestamp): \(.involvedObject.namespace)/\(.involvedObject.name) - \(.reason): \(.message)"'
else
    echo -e "${GREEN}✓ No warning events${NC}"
fi
echo ""

echo "9. Network Policies"
echo "------------------"
netpols=$(kubectl get networkpolicies --all-namespaces -o json | jq '.items | length')
if [ "$netpols" -gt 0 ]; then
    echo "Network policies found: $netpols"
    kubectl get networkpolicies --all-namespaces -o json | jq -r '.items | group_by(.metadata.namespace) | .[] | "\(.[0].metadata.namespace): \(length) policies"'
else
    echo "No network policies configured"
fi
echo ""

echo "10. Certificates Expiration"
echo "--------------------------"
# Check for cert-manager if installed
if kubectl get namespace cert-manager &> /dev/null; then
    echo "cert-manager found, checking certificates..."
    expired_certs=$(kubectl get certificate --all-namespaces -o json | jq '[.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "False"))] | length')
    total_certs=$(kubectl get certificate --all-namespaces -o json | jq '.items | length')
    
    if [ "$total_certs" -gt 0 ]; then
        if [ "$expired_certs" -eq 0 ]; then
            echo -e "${GREEN}✓ All $total_certs certificates are valid${NC}"
        else
            echo -e "${YELLOW}⚠ $expired_certs/$total_certs certificates have issues${NC}"
        fi
    fi
else
    echo "cert-manager not found, skipping certificate checks"
fi
echo ""

echo "======================================"
echo "Cluster Health Check Complete"
echo ""
echo "Summary:"
echo -e "- Nodes: $ready_nodes/$total_nodes ready"
echo -e "- Pods: $running_pods/$total_pods running"
echo -e "- System pods: $running_system_pods/$total_system_pods running"
[ "$failed_pvs" -gt 0 ] && echo -e "- ${RED}Storage issues: $failed_pvs failed PVs${NC}"
[ "$recent_warnings" -gt 0 ] && echo -e "- ${YELLOW}Warning events: $recent_warnings${NC}"
echo "======================================"
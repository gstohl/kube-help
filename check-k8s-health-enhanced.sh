#!/bin/bash

# Enhanced Kubernetes Cluster Health Check Script
# This script performs a comprehensive health check of the Kubernetes cluster
# with advanced diagnostics and recommendations

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
CRITICAL_NAMESPACES=("kube-system" "kube-public" "kube-node-lease")
HIGH_RESTART_THRESHOLD=5
CERTIFICATE_WARNING_DAYS=30
DISK_USAGE_WARNING_PERCENT=80
MEMORY_USAGE_WARNING_PERCENT=85
CPU_USAGE_WARNING_PERCENT=85

echo "=========================================="
echo "Enhanced Kubernetes Cluster Health Check"
echo "=========================================="
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

# Get current context
CURRENT_CONTEXT=$(kubectl config current-context)
echo "Current context: $CURRENT_CONTEXT"
echo ""

echo "1. Cluster Version and API Resources"
echo "-----------------------------------"
# Get server version
SERVER_VERSION=$(kubectl version -o json | jq -r '.serverVersion | "\(.major).\(.minor) (\(.gitVersion))"')
CLIENT_VERSION=$(kubectl version -o json | jq -r '.clientVersion | "\(.major).\(.minor) (\(.gitVersion))"')
echo "Server Version: $SERVER_VERSION"
echo "Client Version: $CLIENT_VERSION"

# Check version compatibility
SERVER_MINOR=$(kubectl version -o json | jq -r '.serverVersion.minor' | sed 's/[^0-9]*//g')
CLIENT_MINOR=$(kubectl version -o json | jq -r '.clientVersion.minor' | sed 's/[^0-9]*//g')
VERSION_DIFF=$((CLIENT_MINOR - SERVER_MINOR))

if [ "$VERSION_DIFF" -gt 1 ] || [ "$VERSION_DIFF" -lt -1 ]; then
    echo -e "${YELLOW}⚠ Warning: Client and server versions differ by more than 1 minor version${NC}"
fi

# Check available API resources
echo ""
echo "API Resources health:"
api_resources=$(kubectl api-resources --verbs=list -o name 2>&1)
if echo "$api_resources" | grep -q "error"; then
    echo -e "${RED}✗ Some API resources are unavailable${NC}"
else
    api_count=$(echo "$api_resources" | wc -l)
    echo -e "${GREEN}✓ $api_count API resources available${NC}"
fi

# Check deprecated APIs
echo ""
echo "Checking for deprecated API usage..."
deprecated_apis=$(kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis | grep -v "# " | wc -l || echo "0")
if [ "$deprecated_apis" -gt 0 ]; then
    echo -e "${YELLOW}⚠ Found $deprecated_apis deprecated API calls${NC}"
else
    echo -e "${GREEN}✓ No deprecated API usage detected${NC}"
fi
echo ""

echo "2. Advanced Node Health Check"
echo "----------------------------"
nodes=$(kubectl get nodes -o json)
total_nodes=$(echo "$nodes" | jq '.items | length')
ready_nodes=$(echo "$nodes" | jq '[.items[] | select(.status.conditions[] | select(.type == "Ready" and .status == "True"))] | length')

echo "Total nodes: $total_nodes"
echo "Node breakdown by role:"
master_nodes=$(echo "$nodes" | jq '[.items[] | select(.metadata.labels."node-role.kubernetes.io/master" == "true" or .metadata.labels."node-role.kubernetes.io/control-plane" == "true")] | length')
worker_nodes=$((total_nodes - master_nodes))
echo "  Control plane nodes: $master_nodes"
echo "  Worker nodes: $worker_nodes"

# Node status details
if [ "$ready_nodes" -eq "$total_nodes" ]; then
    echo -e "${GREEN}✓ All nodes are Ready: $ready_nodes/$total_nodes${NC}"
else
    echo -e "${YELLOW}⚠ Ready nodes: $ready_nodes/$total_nodes${NC}"
fi

# Check node conditions in detail
echo ""
echo "Node Conditions Summary:"
for condition in "Ready" "MemoryPressure" "DiskPressure" "PIDPressure" "NetworkUnavailable"; do
    true_count=$(echo "$nodes" | jq "[.items[] | select(.status.conditions[] | select(.type == \"$condition\" and .status == \"True\"))] | length")
    if [ "$condition" = "Ready" ]; then
        [ "$true_count" -eq "$total_nodes" ] && echo -e "  ${GREEN}✓ $condition: $true_count/$total_nodes${NC}" || echo -e "  ${YELLOW}⚠ $condition: $true_count/$total_nodes${NC}"
    else
        [ "$true_count" -eq 0 ] && echo -e "  ${GREEN}✓ No $condition${NC}" || echo -e "  ${YELLOW}⚠ $condition on $true_count nodes${NC}"
    fi
done

# Check node capacity and allocatable resources
echo ""
echo "Node Resource Capacity:"
echo "$nodes" | jq -r '.items[] | "\(.metadata.name):\n  CPU: \(.status.capacity.cpu) (allocatable: \(.status.allocatable.cpu))\n  Memory: \(.status.capacity.memory) (allocatable: \(.status.allocatable.memory))\n  Pods: \(.status.capacity.pods) (allocatable: \(.status.allocatable.pods))"'

# Check node kernel versions
echo ""
echo "Node OS/Kernel versions:"
echo "$nodes" | jq -r '.items[] | "\(.metadata.name): \(.status.nodeInfo.osImage) - Kernel: \(.status.nodeInfo.kernelVersion)"' | sort | uniq -c | sort -rn

echo ""
echo "3. Control Plane Deep Health Check"
echo "---------------------------------"

# Check all control plane endpoints
echo "API Server endpoints health:"
for endpoint in "/healthz" "/livez" "/readyz"; do
    echo -n "  $endpoint: "
    response=$(kubectl get --raw "$endpoint" 2>&1 || echo "failed")
    if [[ "$response" == "ok" ]]; then
        echo -e "${GREEN}✓ Healthy${NC}"
    else
        echo -e "${RED}✗ Unhealthy${NC}"
        # Check verbose output for readyz
        if [ "$endpoint" = "/readyz" ]; then
            echo "    Checking individual components:"
            kubectl get --raw "/readyz?verbose" 2>/dev/null | grep -E "^\[" | grep -v "ok" | head -5
        fi
    fi
done

# Check control plane component certificates
echo ""
echo "Control Plane Certificates:"
# Try to check API server certificate expiration
if kubectl get configmap -n kube-system cluster-info -o jsonpath='{.data.kubeconfig}' 2>/dev/null | grep -q "certificate-authority-data"; then
    echo -e "${GREEN}✓ Certificate configuration found${NC}"
else
    echo -e "${YELLOW}⚠ Unable to verify certificate configuration${NC}"
fi

# Check admission controllers
echo ""
echo "Admission Controllers:"
admission_config=$(kubectl get pod -n kube-system -l component=kube-apiserver -o jsonpath='{.items[0].spec.containers[0].command}' 2>/dev/null | grep -o "enable-admission-plugins=[^[:space:]]*" || echo "")
if [ -n "$admission_config" ]; then
    echo "  Enabled: ${admission_config#*=}"
else
    echo "  Unable to determine enabled admission controllers"
fi

echo ""
echo "4. System Components Advanced Health"
echo "-----------------------------------"

# Check all system components with detailed status
components=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "etcd" "kube-proxy" "coredns")
for component in "${components[@]}"; do
    echo -n "Checking $component: "
    
    # Try different label selectors
    pod_count=0
    if [ "$component" = "coredns" ]; then
        pod_count=$(kubectl get pods -n kube-system -l k8s-app=kube-dns -o json 2>/dev/null | jq '.items | length')
    else
        pod_count=$(kubectl get pods -n kube-system -l component="$component" -o json 2>/dev/null | jq '.items | length')
        if [ "$pod_count" -eq 0 ]; then
            pod_count=$(kubectl get pods -n kube-system -l k8s-app="$component" -o json 2>/dev/null | jq '.items | length')
        fi
    fi
    
    if [ "$pod_count" -gt 0 ]; then
        running=$(kubectl get pods -n kube-system -l component="$component" -o json 2>/dev/null | jq '[.items[] | select(.status.phase == "Running")] | length' || \
                  kubectl get pods -n kube-system -l k8s-app="$component" -o json 2>/dev/null | jq '[.items[] | select(.status.phase == "Running")] | length' || \
                  kubectl get pods -n kube-system -l k8s-app=kube-dns -o json 2>/dev/null | jq '[.items[] | select(.status.phase == "Running")] | length')
        
        if [ "$running" -eq "$pod_count" ]; then
            echo -e "${GREEN}✓ $running/$pod_count running${NC}"
        else
            echo -e "${YELLOW}⚠ $running/$pod_count running${NC}"
        fi
        
        # Check for container restarts
        high_restarts=$(kubectl get pods -n kube-system -l component="$component" -o json 2>/dev/null | jq '[.items[] | select(.status.containerStatuses[]?.restartCount > 5)] | length' || echo "0")
        [ "$high_restarts" -gt 0 ] && echo -e "  ${YELLOW}⚠ $high_restarts pod(s) with high restart count${NC}"
    else
        # Check if it's a static pod
        static_pod_count=$(kubectl get pods -n kube-system -o json | jq "[.items[] | select(.metadata.name | startswith(\"$component-\"))] | length")
        if [ "$static_pod_count" -gt 0 ]; then
            echo -e "${GREEN}✓ $static_pod_count static pod(s) found${NC}"
        else
            echo -e "${YELLOW}⚠ Not found${NC}"
        fi
    fi
done

echo ""
echo "5. Advanced Storage Health Check"
echo "-------------------------------"

# Check storage classes
storage_classes=$(kubectl get storageclass -o json)
sc_count=$(echo "$storage_classes" | jq '.items | length')
default_sc=$(echo "$storage_classes" | jq -r '.items[] | select(.metadata.annotations."storageclass.kubernetes.io/is-default-class" == "true") | .metadata.name')

echo "Storage Classes: $sc_count"
if [ -n "$default_sc" ]; then
    echo -e "${GREEN}✓ Default storage class: $default_sc${NC}"
else
    echo -e "${YELLOW}⚠ No default storage class set${NC}"
fi

# Detailed PV/PVC analysis
pvs=$(kubectl get pv -o json)
pvcs=$(kubectl get pvc --all-namespaces -o json)

echo ""
echo "Persistent Volumes by status:"
for status in "Bound" "Available" "Released" "Failed"; do
    count=$(echo "$pvs" | jq "[.items[] | select(.status.phase == \"$status\")] | length")
    [ "$count" -gt 0 ] && echo "  $status: $count"
done

# Check PVC usage by namespace
echo ""
echo "PVC usage by namespace (top 5):"
echo "$pvcs" | jq -r '.items | group_by(.metadata.namespace) | map({namespace: .[0].metadata.namespace, count: length}) | sort_by(.count) | reverse | .[0:5] | .[] | "  \(.namespace): \(.count) PVCs"'

# Check for orphaned PVs
orphaned_pvs=$(echo "$pvs" | jq '[.items[] | select(.status.phase == "Released")] | length')
if [ "$orphaned_pvs" -gt 0 ]; then
    echo -e "${YELLOW}⚠ Found $orphaned_pvs released PVs that may need cleanup${NC}"
fi

echo ""
echo "6. Pod Health Deep Analysis"
echo "--------------------------"

all_pods=$(kubectl get pods --all-namespaces -o json)
total_pods=$(echo "$all_pods" | jq '.items | length')

# Pod phase distribution
echo "Pod Phase Distribution:"
for phase in "Running" "Pending" "Succeeded" "Failed" "Unknown"; do
    count=$(echo "$all_pods" | jq "[.items[] | select(.status.phase == \"$phase\")] | length")
    percentage=$((count * 100 / total_pods))
    [ "$count" -gt 0 ] && echo "  $phase: $count ($percentage%)"
done

# Container status analysis
echo ""
echo "Container Status Analysis:"
total_containers=$(echo "$all_pods" | jq '[.items[].spec.containers[]] | length')
waiting_containers=$(echo "$all_pods" | jq '[.items[].status.containerStatuses[]? | select(.state.waiting != null)] | length')
terminated_containers=$(echo "$all_pods" | jq '[.items[].status.containerStatuses[]? | select(.state.terminated != null)] | length')

echo "  Total containers: $total_containers"
[ "$waiting_containers" -gt 0 ] && echo -e "  ${YELLOW}⚠ Waiting: $waiting_containers${NC}"
[ "$terminated_containers" -gt 0 ] && echo -e "  ${YELLOW}⚠ Terminated: $terminated_containers${NC}"

# Top reasons for pod failures
if [ "$waiting_containers" -gt 0 ]; then
    echo ""
    echo "Top waiting reasons:"
    echo "$all_pods" | jq -r '[.items[].status.containerStatuses[]? | select(.state.waiting != null) | .state.waiting.reason] | group_by(.) | map({reason: .[0], count: length}) | sort_by(.count) | reverse | .[0:5] | .[] | "  \(.reason): \(.count)"'
fi

# Check for pods in CrashLoopBackOff
crashloop_pods=$(echo "$all_pods" | jq '[.items[] | select(.status.containerStatuses[]?.state.waiting.reason == "CrashLoopBackOff")] | length')
if [ "$crashloop_pods" -gt 0 ]; then
    echo -e "${RED}✗ $crashloop_pods pod(s) in CrashLoopBackOff${NC}"
fi

# OOMKilled containers
oom_containers=$(echo "$all_pods" | jq '[.items[].status.containerStatuses[]? | select(.state.terminated.reason == "OOMKilled" or .lastState.terminated.reason == "OOMKilled")] | length')
if [ "$oom_containers" -gt 0 ]; then
    echo -e "${YELLOW}⚠ $oom_containers container(s) were OOMKilled${NC}"
fi

echo ""
echo "7. Resource Usage Analysis"
echo "------------------------"

# Check if metrics-server is available
if kubectl top nodes &> /dev/null; then
    echo "Node Resource Usage:"
    kubectl top nodes | head -10
    
    echo ""
    echo "Top 10 CPU consuming pods:"
    kubectl top pods --all-namespaces --sort-by=cpu | head -11
    
    echo ""
    echo "Top 10 Memory consuming pods:"
    kubectl top pods --all-namespaces --sort-by=memory | head -11
    
    # Calculate cluster-wide resource usage
    echo ""
    echo "Cluster Resource Summary:"
    node_metrics=$(kubectl top nodes --no-headers)
    if [ -n "$node_metrics" ]; then
        total_cpu_percent=$(echo "$node_metrics" | awk '{sum+=$3} END {print sum/NR}')
        total_mem_percent=$(echo "$node_metrics" | awk '{sum+=$5} END {print sum/NR}')
        echo "  Average CPU usage: ${total_cpu_percent}%"
        echo "  Average Memory usage: ${total_mem_percent}%"
        
        # Check for resource pressure
        high_cpu_nodes=$(echo "$node_metrics" | awk '$3 > 85 {print $1}' | wc -l)
        high_mem_nodes=$(echo "$node_metrics" | awk '$5 > 85 {print $1}' | wc -l)
        
        [ "$high_cpu_nodes" -gt 0 ] && echo -e "  ${YELLOW}⚠ $high_cpu_nodes node(s) with CPU usage > 85%${NC}"
        [ "$high_mem_nodes" -gt 0 ] && echo -e "  ${YELLOW}⚠ $high_mem_nodes node(s) with Memory usage > 85%${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Metrics not available (metrics-server not installed or not ready)${NC}"
fi

echo ""
echo "8. Network and Service Health"
echo "---------------------------"

# Service analysis
services=$(kubectl get services --all-namespaces -o json)
total_services=$(echo "$services" | jq '.items | length')
service_types=$(echo "$services" | jq -r '.items | group_by(.spec.type) | map({type: .[0].spec.type, count: length}) | .[] | "  \(.type): \(.count)"')

echo "Total Services: $total_services"
echo "Service Types:"
echo "$service_types"

# Check for services without endpoints
echo ""
echo "Checking service endpoints..."
services_without_endpoints=0
for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}'); do
    for svc in $(kubectl get services -n "$ns" -o jsonpath='{.items[*].metadata.name}'); do
        endpoints=$(kubectl get endpoints -n "$ns" "$svc" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
        if [ -z "$endpoints" ] && [ "$svc" != "kubernetes" ]; then
            ((services_without_endpoints++))
        fi
    done
done

if [ "$services_without_endpoints" -eq 0 ]; then
    echo -e "${GREEN}✓ All services have endpoints${NC}"
else
    echo -e "${YELLOW}⚠ $services_without_endpoints service(s) without endpoints${NC}"
fi

# Check Ingress resources
ingress_count=$(kubectl get ingress --all-namespaces -o json | jq '.items | length')
if [ "$ingress_count" -gt 0 ]; then
    echo ""
    echo "Ingress Resources: $ingress_count"
    ingress_without_address=$(kubectl get ingress --all-namespaces -o json | jq '[.items[] | select(.status.loadBalancer.ingress == null)] | length')
    if [ "$ingress_without_address" -gt 0 ]; then
        echo -e "${YELLOW}⚠ $ingress_without_address ingress(es) without address${NC}"
    else
        echo -e "${GREEN}✓ All ingresses have addresses${NC}"
    fi
fi

echo ""
echo "9. Security and Compliance Checks"
echo "--------------------------------"

# Check for pods running as root
root_pods=$(echo "$all_pods" | jq '[.items[] | select(.spec.containers[]?.securityContext.runAsUser == 0 or .spec.securityContext.runAsUser == 0)] | length')
echo "Security Context Analysis:"
echo "  Pods potentially running as root: $root_pods"

# Check for pods with privileged containers
privileged_pods=$(echo "$all_pods" | jq '[.items[] | select(.spec.containers[]?.securityContext.privileged == true)] | length')
echo "  Pods with privileged containers: $privileged_pods"

# Check for pods with host network
host_network_pods=$(echo "$all_pods" | jq '[.items[] | select(.spec.hostNetwork == true)] | length')
echo "  Pods using host network: $host_network_pods"

# Check for default service accounts
default_sa_pods=$(echo "$all_pods" | jq '[.items[] | select(.spec.serviceAccountName == "default" or .spec.serviceAccountName == null)] | length')
echo "  Pods using default service account: $default_sa_pods"

# Check Pod Security Standards
if kubectl get namespaces -o json | jq -e '.items[0].metadata.labels | has("pod-security.kubernetes.io/enforce")' &> /dev/null; then
    echo ""
    echo "Pod Security Standards:"
    kubectl get namespaces -o json | jq -r '.items[] | select(.metadata.labels | keys[] | contains("pod-security.kubernetes.io")) | "\(.metadata.name): \(.metadata.labels | to_entries | map(select(.key | contains("pod-security.kubernetes.io"))) | map("\(.key)=\(.value)") | join(", "))"' | head -10
else
    echo -e "${YELLOW}⚠ Pod Security Standards not configured${NC}"
fi

echo ""
echo "10. Recent Events Analysis"
echo "------------------------"

# Analyze events by type and reason
events=$(kubectl get events --all-namespaces -o json)
total_events=$(echo "$events" | jq '.items | length')
warning_events=$(echo "$events" | jq '[.items[] | select(.type == "Warning")] | length')

echo "Total events: $total_events"
echo "Warning events: $warning_events"

if [ "$warning_events" -gt 0 ]; then
    echo ""
    echo "Top warning event reasons:"
    echo "$events" | jq -r '[.items[] | select(.type == "Warning") | .reason] | group_by(.) | map({reason: .[0], count: length}) | sort_by(.count) | reverse | .[0:10] | .[] | "  \(.reason): \(.count)"'
    
    echo ""
    echo "Recent critical warnings:"
    echo "$events" | jq -r '.items[] | select(.type == "Warning" and (.reason == "OOMKilling" or .reason == "SystemOOM" or .reason == "FailedScheduling" or .reason == "FailedMount")) | "\(.lastTimestamp): \(.involvedObject.namespace)/\(.involvedObject.name) - \(.reason): \(.message)"' | tail -5
fi

echo ""
echo "11. Cluster Capacity Planning"
echo "---------------------------"

# Calculate pod capacity
total_pod_capacity=$(echo "$nodes" | jq '[.items[].status.allocatable.pods | tonumber] | add')
current_pod_count="$total_pods"
pod_usage_percent=$((current_pod_count * 100 / total_pod_capacity))

echo "Pod Capacity:"
echo "  Total capacity: $total_pod_capacity"
echo "  Current usage: $current_pod_count ($pod_usage_percent%)"

if [ "$pod_usage_percent" -gt 80 ]; then
    echo -e "  ${YELLOW}⚠ High pod usage - consider adding nodes${NC}"
fi

# Namespace resource distribution
echo ""
echo "Resource distribution by namespace (top 10):"
namespace_pod_count=$(echo "$all_pods" | jq -r '.items | group_by(.metadata.namespace) | map({namespace: .[0].metadata.namespace, pods: length}) | sort_by(.pods) | reverse | .[0:10] | .[] | "  \(.namespace): \(.pods) pods"')
echo "$namespace_pod_count"

echo ""
echo "12. Recommendations"
echo "------------------"

recommendations=0

# Node recommendations
if [ "$ready_nodes" -lt "$total_nodes" ]; then
    echo -e "${YELLOW}• Fix NotReady nodes before they impact workload availability${NC}"
    ((recommendations++))
fi

# Storage recommendations
if [ -z "$default_sc" ]; then
    echo -e "${YELLOW}• Set a default StorageClass for dynamic provisioning${NC}"
    ((recommendations++))
fi

if [ "$orphaned_pvs" -gt 0 ]; then
    echo -e "${YELLOW}• Clean up $orphaned_pvs released PersistentVolumes${NC}"
    ((recommendations++))
fi

# Pod recommendations
if [ "$crashloop_pods" -gt 0 ]; then
    echo -e "${RED}• Investigate and fix $crashloop_pods pods in CrashLoopBackOff${NC}"
    ((recommendations++))
fi

if [ "$oom_containers" -gt 0 ]; then
    echo -e "${YELLOW}• Review memory limits for containers that were OOMKilled${NC}"
    ((recommendations++))
fi

# Security recommendations
if [ "$privileged_pods" -gt 0 ]; then
    echo -e "${YELLOW}• Review $privileged_pods pods running with privileged containers${NC}"
    ((recommendations++))
fi

if [ "$root_pods" -gt 20 ]; then
    echo -e "${YELLOW}• Consider implementing Pod Security Standards to limit root containers${NC}"
    ((recommendations++))
fi

# Resource recommendations
if [ -n "$high_cpu_nodes" ] && [ "$high_cpu_nodes" -gt 0 ]; then
    echo -e "${YELLOW}• Address high CPU usage on $high_cpu_nodes nodes${NC}"
    ((recommendations++))
fi

if [ "$pod_usage_percent" -gt 80 ]; then
    echo -e "${YELLOW}• Pod capacity at $pod_usage_percent% - plan for cluster expansion${NC}"
    ((recommendations++))
fi

if [ "$recommendations" -eq 0 ]; then
    echo -e "${GREEN}✓ No critical recommendations - cluster is healthy!${NC}"
fi

echo ""
echo "=========================================="
echo "Enhanced Health Check Complete"
echo ""
echo "Summary:"
echo -e "- Cluster: $CURRENT_CONTEXT"
echo -e "- Nodes: $ready_nodes/$total_nodes ready"
echo -e "- Pods: $running_pods/$total_pods running"
echo -e "- Services: $total_services"
echo -e "- Storage: $sc_count storage classes, $total_pvs PVs"
[ "$warning_events" -gt 0 ] && echo -e "- ${YELLOW}Warning events: $warning_events${NC}"
[ "$recommendations" -gt 0 ] && echo -e "- ${YELLOW}Recommendations: $recommendations${NC}"
echo "==========================================="
#!/bin/bash

# Node Health and Resources Check Script
# This script performs deep health analysis of Kubernetes nodes

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Thresholds
CPU_WARNING=80
CPU_CRITICAL=90
MEMORY_WARNING=85
MEMORY_CRITICAL=95
DISK_WARNING=80
DISK_CRITICAL=90
INODE_WARNING=80
INODE_CRITICAL=90
PID_WARNING=30000
PID_CRITICAL=32768

echo "======================================"
echo "Kubernetes Node Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

echo "1. Node Overview"
echo "---------------"

# Get all nodes
nodes=$(kubectl get nodes -o json)
total_nodes=$(echo "$nodes" | jq '.items | length')

echo "Total nodes in cluster: $total_nodes"
echo ""

# Node summary by status
echo "Node Status Summary:"
for status in "Ready" "NotReady" "SchedulingDisabled"; do
    if [ "$status" = "SchedulingDisabled" ]; then
        count=$(echo "$nodes" | jq '[.items[] | select(.spec.unschedulable == true)] | length')
    else
        count=$(echo "$nodes" | jq "[.items[] | select(.status.conditions[] | select(.type == \"Ready\" and .status == \"$([ "$status" = "Ready" ] && echo "True" || echo "False")\"))] | length")
    fi
    
    if [ "$count" -gt 0 ]; then
        if [ "$status" = "Ready" ]; then
            echo -e "  ${GREEN}✓ $status: $count${NC}"
        else
            echo -e "  ${YELLOW}⚠ $status: $count${NC}"
        fi
    fi
done

# Node roles
echo ""
echo "Node Roles:"
control_plane=$(echo "$nodes" | jq '[.items[] | select(.metadata.labels | has("node-role.kubernetes.io/control-plane") or has("node-role.kubernetes.io/master"))] | length')
workers=$((total_nodes - control_plane))
echo "  Control Plane: $control_plane"
echo "  Workers: $workers"

# Check for custom labels/taints
echo ""
echo "Nodes with taints:"
tainted_nodes=$(echo "$nodes" | jq '[.items[] | select(.spec.taints != null and (.spec.taints | length) > 0)] | length')
echo "  Tainted nodes: $tainted_nodes"

echo ""
echo "2. Node Conditions Deep Dive"
echo "---------------------------"

# Analyze each node
for i in $(seq 0 $((total_nodes - 1))); do
    node=$(echo "$nodes" | jq ".items[$i]")
    node_name=$(echo "$node" | jq -r '.metadata.name')
    
    echo ""
    echo -e "${BLUE}Node: $node_name${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━"
    
    # Node info
    kernel=$(echo "$node" | jq -r '.status.nodeInfo.kernelVersion')
    os=$(echo "$node" | jq -r '.status.nodeInfo.osImage')
    container_runtime=$(echo "$node" | jq -r '.status.nodeInfo.containerRuntimeVersion')
    kubelet=$(echo "$node" | jq -r '.status.nodeInfo.kubeletVersion')
    
    echo "System Info:"
    echo "  OS: $os"
    echo "  Kernel: $kernel"
    echo "  Container Runtime: $container_runtime"
    echo "  Kubelet: $kubelet"
    
    # Creation time and age
    created=$(echo "$node" | jq -r '.metadata.creationTimestamp')
    echo "  Created: $created"
    
    # Check all conditions
    echo ""
    echo "Conditions:"
    conditions=$(echo "$node" | jq -r '.status.conditions[] | "  \(.type): \(.status) (Reason: \(.reason // "None"), Message: \(.message // "None"))"')
    
    # Color code conditions
    while IFS= read -r condition; do
        if echo "$condition" | grep -q "True"; then
            if echo "$condition" | grep -E "Ready:" | grep -q "True"; then
                echo -e "${GREEN}$condition${NC}"
            elif echo "$condition" | grep -E "MemoryPressure:|DiskPressure:|PIDPressure:" | grep -q "True"; then
                echo -e "${RED}$condition${NC}"
            else
                echo "$condition"
            fi
        else
            if echo "$condition" | grep "Ready:" | grep -q "False"; then
                echo -e "${RED}$condition${NC}"
            else
                echo -e "${GREEN}$condition${NC}"
            fi
        fi
    done <<< "$conditions"
    
    # Node capacity and allocatable
    echo ""
    echo "Resources:"
    cpu_capacity=$(echo "$node" | jq -r '.status.capacity.cpu')
    cpu_allocatable=$(echo "$node" | jq -r '.status.allocatable.cpu')
    mem_capacity=$(echo "$node" | jq -r '.status.capacity.memory')
    mem_allocatable=$(echo "$node" | jq -r '.status.allocatable.memory')
    pods_capacity=$(echo "$node" | jq -r '.status.capacity.pods')
    pods_allocatable=$(echo "$node" | jq -r '.status.allocatable.pods')
    
    echo "  CPU: $cpu_allocatable allocatable / $cpu_capacity capacity"
    echo "  Memory: $mem_allocatable allocatable / $mem_capacity capacity"
    echo "  Max Pods: $pods_allocatable allocatable / $pods_capacity capacity"
    
    # Calculate memory in GB for readability
    if command -v numfmt &> /dev/null; then
        mem_capacity_gb=$(echo "$mem_capacity" | sed 's/Ki$//' | numfmt --from=iec --to=iec --suffix=B | sed 's/K/ KB/; s/M/ MB/; s/G/ GB/')
        mem_allocatable_gb=$(echo "$mem_allocatable" | sed 's/Ki$//' | numfmt --from=iec --to=iec --suffix=B | sed 's/K/ KB/; s/M/ MB/; s/G/ GB/')
        echo "  Memory (Human): $mem_allocatable_gb allocatable / $mem_capacity_gb capacity"
    fi
    
    # Node addresses
    echo ""
    echo "Addresses:"
    echo "$node" | jq -r '.status.addresses[] | "  \(.type): \(.address)"'
    
    # Node taints
    taints=$(echo "$node" | jq -r '.spec.taints[]? | "  \(.key)=\(.value // ""):\(.effect)"')
    if [ -n "$taints" ]; then
        echo ""
        echo "Taints:"
        echo "$taints"
    fi
    
    # Pod count on node
    pod_count=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node_name" -o json | jq '.items | length')
    echo ""
    echo "Workload:"
    echo "  Running pods: $pod_count / $pods_allocatable"
    
    # Check for critical pods
    critical_pods=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node_name" -o json | jq '[.items[] | select(.metadata.namespace == "kube-system")] | length')
    echo "  System pods: $critical_pods"
done

echo ""
echo "3. Node Resource Usage Analysis"
echo "------------------------------"

# Check if metrics-server is available
if kubectl top nodes &> /dev/null; then
    echo "Current Resource Usage:"
    echo ""
    
    # Get node metrics
    node_metrics=$(kubectl top nodes --no-headers 2>/dev/null)
    
    if [ -n "$node_metrics" ]; then
        # Header
        printf "%-30s %10s %10s %15s %15s\n" "NODE" "CPU%" "CPU" "MEMORY%" "MEMORY"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        while IFS= read -r line; do
            node_name=$(echo "$line" | awk '{print $1}')
            cpu_usage=$(echo "$line" | awk '{print $3}' | sed 's/%//')
            cpu_value=$(echo "$line" | awk '{print $2}')
            mem_usage=$(echo "$line" | awk '{print $5}' | sed 's/%//')
            mem_value=$(echo "$line" | awk '{print $4}')
            
            # Color code based on usage
            cpu_color="$GREEN"
            mem_color="$GREEN"
            
            [ "$cpu_usage" -ge "$CPU_WARNING" ] && cpu_color="$YELLOW"
            [ "$cpu_usage" -ge "$CPU_CRITICAL" ] && cpu_color="$RED"
            [ "$mem_usage" -ge "$MEMORY_WARNING" ] && mem_color="$YELLOW"
            [ "$mem_usage" -ge "$MEMORY_CRITICAL" ] && mem_color="$RED"
            
            printf "%-30s ${cpu_color}%10s%% %10s${NC} ${mem_color}%15s%% %15s${NC}\n" \
                "$node_name" "$cpu_usage" "$cpu_value" "$mem_usage" "$mem_value"
        done <<< "$node_metrics"
        
        # Calculate averages
        echo ""
        avg_cpu=$(echo "$node_metrics" | awk '{sum+=$3; count++} END {printf "%.1f", sum/count}')
        avg_mem=$(echo "$node_metrics" | awk '{sum+=$5; count++} END {printf "%.1f", sum/count}')
        
        echo "Cluster Averages:"
        echo "  CPU Usage: ${avg_cpu}%"
        echo "  Memory Usage: ${avg_mem}%"
        
        # Warning if high usage
        high_cpu_nodes=$(echo "$node_metrics" | awk -v threshold="$CPU_WARNING" '$3 > threshold {count++} END {print count+0}')
        high_mem_nodes=$(echo "$node_metrics" | awk -v threshold="$MEMORY_WARNING" '$5 > threshold {count++} END {print count+0}')
        
        if [ "$high_cpu_nodes" -gt 0 ] || [ "$high_mem_nodes" -gt 0 ]; then
            echo ""
            echo "Resource Warnings:"
            [ "$high_cpu_nodes" -gt 0 ] && echo -e "  ${YELLOW}⚠ $high_cpu_nodes node(s) with CPU usage > ${CPU_WARNING}%${NC}"
            [ "$high_mem_nodes" -gt 0 ] && echo -e "  ${YELLOW}⚠ $high_mem_nodes node(s) with Memory usage > ${MEMORY_WARNING}%${NC}"
        fi
    fi
else
    echo -e "${YELLOW}⚠ Metrics not available (metrics-server not installed or not ready)${NC}"
fi

echo ""
echo "4. Node Storage Analysis"
echo "----------------------"

# For each node, check volume usage
echo "Checking node storage..."

for i in $(seq 0 $((total_nodes - 1))); do
    node_name=$(echo "$nodes" | jq -r ".items[$i].metadata.name")
    
    echo ""
    echo -e "${BLUE}Node: $node_name${NC}"
    
    # Get node's volume information
    volumes_in_use=$(echo "$nodes" | jq -r ".items[$i].status.volumesInUse[]?" 2>/dev/null | wc -l)
    volumes_attached=$(echo "$nodes" | jq -r ".items[$i].status.volumesAttached[]?" 2>/dev/null | wc -l)
    
    echo "  Volumes in use: $volumes_in_use"
    echo "  Volumes attached: $volumes_attached"
    
    # Check for image filesystem usage
    image_fs=$(echo "$nodes" | jq -r ".items[$i].status.nodeInfo.systemUUID" 2>/dev/null)
    if [ -n "$image_fs" ]; then
        # Try to get disk pressure info from events
        disk_events=$(kubectl get events --field-selector involvedObject.name="$node_name",reason=NodeHasDiskPressure -o json 2>/dev/null | jq '.items | length')
        if [ "$disk_events" -gt 0 ]; then
            echo -e "  ${YELLOW}⚠ Recent disk pressure events: $disk_events${NC}"
        fi
    fi
done

echo ""
echo "5. Node Events Analysis"
echo "---------------------"

# Analyze events for each node
echo "Checking node-related events..."

for i in $(seq 0 $((total_nodes - 1))); do
    node_name=$(echo "$nodes" | jq -r ".items[$i].metadata.name")
    
    # Get events for this node
    node_events=$(kubectl get events --field-selector involvedObject.name="$node_name" -o json)
    event_count=$(echo "$node_events" | jq '.items | length')
    
    if [ "$event_count" -gt 0 ]; then
        warning_count=$(echo "$node_events" | jq '[.items[] | select(.type == "Warning")] | length')
        
        if [ "$warning_count" -gt 0 ]; then
            echo ""
            echo -e "${YELLOW}Node: $node_name - $warning_count warning event(s)${NC}"
            
            # Show recent warnings
            recent_warnings=$(echo "$node_events" | jq -r '.items[] | select(.type == "Warning") | "\(.lastTimestamp): \(.reason) - \(.message)"' | tail -5)
            echo "$recent_warnings" | sed 's/^/  /'
        fi
    fi
done

echo ""
echo "6. Node Network Configuration"
echo "---------------------------"

# Check node network plugins and configuration
echo "Network Configuration:"

# Check for network plugin
cni_conf=$(kubectl get nodes -o json | jq -r '.items[0].status.nodeInfo.systemUUID' 2>/dev/null)
echo "  CNI Plugin: Checking pods for network solution..."

# Common CNI solutions
for cni in "calico" "weave" "flannel" "cilium" "canal" "kube-router"; do
    if kubectl get pods --all-namespaces | grep -qi "$cni"; then
        echo -e "  ${GREEN}✓ Found $cni CNI${NC}"
    fi
done

# Check for NetworkPolicies support
if kubectl api-resources | grep -q "networkpolicies"; then
    echo -e "  ${GREEN}✓ NetworkPolicies supported${NC}"
fi

echo ""
echo "7. Node Security Analysis"
echo "-----------------------"

echo "Security Configuration:"

# Check kernel security features
for i in $(seq 0 $((total_nodes - 1))); do
    node_name=$(echo "$nodes" | jq -r ".items[$i].metadata.name")
    kernel_version=$(echo "$nodes" | jq -r ".items[$i].status.nodeInfo.kernelVersion")
    
    echo ""
    echo "Node: $node_name"
    echo "  Kernel: $kernel_version"
    
    # Check for SELinux/AppArmor
    os_image=$(echo "$nodes" | jq -r ".items[$i].status.nodeInfo.osImage")
    if echo "$os_image" | grep -qi "ubuntu"; then
        echo "  Security Module: AppArmor (Ubuntu default)"
    elif echo "$os_image" | grep -qi "centos\|rhel\|fedora"; then
        echo "  Security Module: SELinux (RHEL/CentOS default)"
    fi
done

echo ""
echo "8. Node Pod Distribution"
echo "----------------------"

echo "Pod distribution across nodes:"
echo ""

# Create distribution table
printf "%-30s %10s %15s %20s\n" "NODE" "PODS" "SYSTEM PODS" "USER PODS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for i in $(seq 0 $((total_nodes - 1))); do
    node_name=$(echo "$nodes" | jq -r ".items[$i].metadata.name")
    
    # Get pod counts
    total_pods=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node_name" -o json | jq '.items | length')
    system_pods=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node_name" -o json | jq '[.items[] | select(.metadata.namespace == "kube-system")] | length')
    user_pods=$((total_pods - system_pods))
    
    # Calculate percentage of cluster pods
    all_pods=$(kubectl get pods --all-namespaces -o json | jq '.items | length')
    percentage=$((total_pods * 100 / all_pods))
    
    printf "%-30s %10s %15s %20s (%d%%)\n" "$node_name" "$total_pods" "$system_pods" "$user_pods" "$percentage"
done

echo ""
echo "9. Node Readiness Gates"
echo "---------------------"

# Check for custom node conditions
echo "Checking for custom conditions and readiness gates..."

custom_conditions=0
for i in $(seq 0 $((total_nodes - 1))); do
    node=$(echo "$nodes" | jq ".items[$i]")
    node_name=$(echo "$node" | jq -r '.metadata.name')
    
    # Check for non-standard conditions
    conditions=$(echo "$node" | jq -r '.status.conditions[].type' | grep -v -E "^(Ready|MemoryPressure|DiskPressure|PIDPressure|NetworkUnavailable)$" || true)
    
    if [ -n "$conditions" ]; then
        echo ""
        echo "Node: $node_name"
        echo "  Custom conditions: $conditions"
        ((custom_conditions++))
    fi
done

if [ "$custom_conditions" -eq 0 ]; then
    echo -e "${GREEN}✓ No custom node conditions found${NC}"
fi

echo ""
echo "10. Recommendations"
echo "-----------------"

recommendations=0

# Check for NotReady nodes
not_ready=$(echo "$nodes" | jq '[.items[] | select(.status.conditions[] | select(.type == "Ready" and .status != "True"))] | length')
if [ "$not_ready" -gt 0 ]; then
    echo -e "${RED}• Critical: $not_ready node(s) are NotReady${NC}"
    ((recommendations++))
fi

# Check for high resource usage
if [ -n "${high_cpu_nodes:-}" ] && [ "$high_cpu_nodes" -gt 0 ]; then
    echo -e "${YELLOW}• Consider scaling out - $high_cpu_nodes node(s) have high CPU usage${NC}"
    ((recommendations++))
fi

if [ -n "${high_mem_nodes:-}" ] && [ "$high_mem_nodes" -gt 0 ]; then
    echo -e "${YELLOW}• Consider scaling out - $high_mem_nodes node(s) have high memory usage${NC}"
    ((recommendations++))
fi

# Check for uneven distribution
if [ "$total_nodes" -gt 1 ]; then
    # Calculate standard deviation of pod distribution
    pod_counts=$(kubectl get pods --all-namespaces -o json | jq -r '.items | group_by(.spec.nodeName) | map(length) | @csv' | tr ',' '\n')
    if [ -n "$pod_counts" ]; then
        avg_pods=$(echo "$pod_counts" | awk '{sum+=$1; count++} END {print sum/count}')
        max_pods=$(echo "$pod_counts" | sort -nr | head -1)
        min_pods=$(echo "$pod_counts" | sort -n | head -1)
        
        if [ "$max_pods" -gt $((min_pods * 2)) ] && [ "$min_pods" -gt 0 ]; then
            echo -e "${YELLOW}• Pod distribution is uneven (max: $max_pods, min: $min_pods)${NC}"
            ((recommendations++))
        fi
    fi
fi

# Check for old kernels
old_kernels=$(echo "$nodes" | jq -r '.items[].status.nodeInfo.kernelVersion' | grep -E "^[234]\." | wc -l || echo "0")
if [ "$old_kernels" -gt 0 ]; then
    echo -e "${YELLOW}• $old_kernels node(s) running kernel version < 5.x${NC}"
    ((recommendations++))
fi

if [ "$recommendations" -eq 0 ]; then
    echo -e "${GREEN}✓ No critical recommendations - nodes are healthy!${NC}"
fi

echo ""
echo "======================================"
echo "Node Health Check Complete"
echo ""
echo "Summary:"
echo "- Total nodes: $total_nodes"
echo "- Ready nodes: $((total_nodes - not_ready))"
echo "- Control plane nodes: $control_plane"
echo "- Worker nodes: $workers"
[ "$tainted_nodes" -gt 0 ] && echo "- Tainted nodes: $tainted_nodes"
[ "$recommendations" -gt 0 ] && echo -e "- ${YELLOW}Recommendations: $recommendations${NC}"
echo "======================================"
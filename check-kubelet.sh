#!/bin/bash

# Kubelet Health Check Script
# This script performs detailed health analysis of kubelet on all nodes

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
echo "Kubelet Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

echo "1. Kubelet Status Overview"
echo "------------------------"

# Get all nodes
nodes=$(kubectl get nodes -o json)
total_nodes=$(echo "$nodes" | jq '.items | length')

echo "Total nodes: $total_nodes"
echo ""

# Check node status
ready_nodes=0
not_ready_nodes=0
unknown_nodes=0

for i in $(seq 0 $((total_nodes - 1))); do
    node=$(echo "$nodes" | jq ".items[$i]")
    node_name=$(echo "$node" | jq -r '.metadata.name')
    
    # Get node condition
    ready_condition=$(echo "$node" | jq -r '.status.conditions[] | select(.type == "Ready") | .status')
    
    if [ "$ready_condition" = "True" ]; then
        ((ready_nodes++))
        status="${GREEN}Ready${NC}"
    elif [ "$ready_condition" = "False" ]; then
        ((not_ready_nodes++))
        status="${RED}NotReady${NC}"
    else
        ((unknown_nodes++))
        status="${YELLOW}Unknown${NC}"
    fi
    
    echo -e "Node $node_name: $status"
done

echo ""
echo "Summary:"
echo -e "  Ready: ${GREEN}$ready_nodes${NC}"
[ "$not_ready_nodes" -gt 0 ] && echo -e "  NotReady: ${RED}$not_ready_nodes${NC}"
[ "$unknown_nodes" -gt 0 ] && echo -e "  Unknown: ${YELLOW}$unknown_nodes${NC}"

echo ""
echo "2. Kubelet Version Analysis"
echo "-------------------------"

# Track kubelet versions
declare -A kubelet_versions

for i in $(seq 0 $((total_nodes - 1))); do
    node=$(echo "$nodes" | jq ".items[$i]")
    node_name=$(echo "$node" | jq -r '.metadata.name')
    kubelet_version=$(echo "$node" | jq -r '.status.nodeInfo.kubeletVersion')
    
    ((kubelet_versions[$kubelet_version]++))
    
    echo "Node $node_name: $kubelet_version"
done

echo ""
echo "Version Distribution:"
for version in "${!kubelet_versions[@]}"; do
    echo "  $version: ${kubelet_versions[$version]} node(s)"
done

if [ ${#kubelet_versions[@]} -gt 1 ]; then
    echo -e "${YELLOW}⚠ Multiple kubelet versions detected${NC}"
fi

echo ""
echo "3. Kubelet Configuration Analysis"
echo "-------------------------------"

# Check for kubelet configuration issues
echo "Checking kubelet conditions on each node..."
echo ""

for i in $(seq 0 $((total_nodes - 1))); do
    node=$(echo "$nodes" | jq ".items[$i]")
    node_name=$(echo "$node" | jq -r '.metadata.name')
    
    echo -e "${BLUE}Node: $node_name${NC}"
    
    # Check all node conditions
    conditions=$(echo "$node" | jq -r '.status.conditions[]')
    
    # Memory pressure
    mem_pressure=$(echo "$conditions" | jq -r 'select(.type == "MemoryPressure") | .status')
    if [ "$mem_pressure" = "True" ]; then
        echo -e "  ${RED}✗ Memory Pressure detected${NC}"
    else
        echo -e "  ${GREEN}✓ No Memory Pressure${NC}"
    fi
    
    # Disk pressure
    disk_pressure=$(echo "$conditions" | jq -r 'select(.type == "DiskPressure") | .status')
    if [ "$disk_pressure" = "True" ]; then
        echo -e "  ${RED}✗ Disk Pressure detected${NC}"
    else
        echo -e "  ${GREEN}✓ No Disk Pressure${NC}"
    fi
    
    # PID pressure
    pid_pressure=$(echo "$conditions" | jq -r 'select(.type == "PIDPressure") | .status')
    if [ "$pid_pressure" = "True" ]; then
        echo -e "  ${RED}✗ PID Pressure detected${NC}"
    else
        echo -e "  ${GREEN}✓ No PID Pressure${NC}"
    fi
    
    # Network unavailable
    network_unavailable=$(echo "$conditions" | jq -r 'select(.type == "NetworkUnavailable") | .status')
    if [ "$network_unavailable" = "True" ]; then
        echo -e "  ${RED}✗ Network Unavailable${NC}"
    else
        echo -e "  ${GREEN}✓ Network Available${NC}"
    fi
    
    # Check kubelet last heartbeat
    ready_condition=$(echo "$conditions" | jq -r 'select(.type == "Ready")')
    last_heartbeat=$(echo "$ready_condition" | jq -r '.lastHeartbeatTime')
    last_transition=$(echo "$ready_condition" | jq -r '.lastTransitionTime')
    
    echo "  Last Heartbeat: $last_heartbeat"
    
    # Calculate time since last heartbeat
    if command -v date &> /dev/null; then
        current_time=$(date +%s)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            heartbeat_time=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_heartbeat" +%s 2>/dev/null || echo "0")
        else
            heartbeat_time=$(date -d "$last_heartbeat" +%s 2>/dev/null || echo "0")
        fi
        
        if [ "$heartbeat_time" -gt 0 ]; then
            time_diff=$((current_time - heartbeat_time))
            if [ "$time_diff" -gt 300 ]; then
                echo -e "  ${YELLOW}⚠ Last heartbeat was ${time_diff}s ago${NC}"
            fi
        fi
    fi
    
    echo ""
done

echo "4. Kubelet Resource Usage"
echo "-----------------------"

# Check if metrics are available
if kubectl top nodes &> /dev/null; then
    echo "Node resource usage:"
    echo ""
    kubectl top nodes
    
    # Analyze high usage
    echo ""
    high_cpu_nodes=$(kubectl top nodes --no-headers 2>/dev/null | awk '$3 > 80 {print $1}' | wc -l || echo "0")
    high_mem_nodes=$(kubectl top nodes --no-headers 2>/dev/null | awk '$5 > 85 {print $1}' | wc -l || echo "0")
    
    if [ "$high_cpu_nodes" -gt 0 ]; then
        echo -e "${YELLOW}⚠ $high_cpu_nodes node(s) with CPU usage > 80%${NC}"
    fi
    
    if [ "$high_mem_nodes" -gt 0 ]; then
        echo -e "${YELLOW}⚠ $high_mem_nodes node(s) with Memory usage > 85%${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Metrics not available (metrics-server may not be installed)${NC}"
fi

echo ""
echo "5. Kubelet Event Analysis"
echo "-----------------------"

# Check for kubelet-related events
echo "Recent kubelet-related events..."

kubelet_events=$(kubectl get events --all-namespaces --field-selector source.component=kubelet -o json)
total_events=$(echo "$kubelet_events" | jq '.items | length')

if [ "$total_events" -gt 0 ]; then
    echo "Total kubelet events: $total_events"
    
    # Count by type
    warning_events=$(echo "$kubelet_events" | jq '[.items[] | select(.type == "Warning")] | length')
    normal_events=$(echo "$kubelet_events" | jq '[.items[] | select(.type == "Normal")] | length')
    
    echo "  Normal: $normal_events"
    echo "  Warning: $warning_events"
    
    if [ "$warning_events" -gt 0 ]; then
        echo ""
        echo "Recent warning events:"
        echo "$kubelet_events" | jq -r '.items[] | select(.type == "Warning") | "\(.lastTimestamp): \(.source.host) - \(.reason): \(.message)"' | tail -10
    fi
    
    # Analyze specific error patterns
    echo ""
    echo "Event patterns:"
    
    oom_kills=$(echo "$kubelet_events" | jq '[.items[] | select(.reason == "OOMKilling")] | length')
    [ "$oom_kills" -gt 0 ] && echo -e "  ${RED}OOM Kills: $oom_kills${NC}"
    
    failed_mounts=$(echo "$kubelet_events" | jq '[.items[] | select(.reason == "FailedMount")] | length')
    [ "$failed_mounts" -gt 0 ] && echo -e "  ${YELLOW}Failed Mounts: $failed_mounts${NC}"
    
    image_pulls=$(echo "$kubelet_events" | jq '[.items[] | select(.reason == "Pulling" or .reason == "Pulled")] | length')
    [ "$image_pulls" -gt 0 ] && echo "  Image Pulls: $image_pulls"
    
    evictions=$(echo "$kubelet_events" | jq '[.items[] | select(.reason == "Evicted")] | length')
    [ "$evictions" -gt 0 ] && echo -e "  ${YELLOW}Pod Evictions: $evictions${NC}"
else
    echo -e "${GREEN}✓ No kubelet events found${NC}"
fi

echo ""
echo "6. Kubelet Pod Management"
echo "-----------------------"

# Check pod distribution and capacity
echo "Pod capacity and usage by node:"
echo ""

total_capacity=0
total_used=0

for i in $(seq 0 $((total_nodes - 1))); do
    node=$(echo "$nodes" | jq ".items[$i]")
    node_name=$(echo "$node" | jq -r '.metadata.name')
    
    # Get pod capacity
    pod_capacity=$(echo "$node" | jq -r '.status.allocatable.pods')
    
    # Get running pods on node
    pods_on_node=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node_name" -o json | jq '.items | length')
    
    # Calculate usage percentage
    usage_percent=$((pods_on_node * 100 / pod_capacity))
    
    total_capacity=$((total_capacity + pod_capacity))
    total_used=$((total_used + pods_on_node))
    
    # Color code based on usage
    if [ "$usage_percent" -gt 90 ]; then
        color="$RED"
    elif [ "$usage_percent" -gt 70 ]; then
        color="$YELLOW"
    else
        color="$GREEN"
    fi
    
    echo -e "$node_name: ${color}$pods_on_node/$pod_capacity pods ($usage_percent%)${NC}"
done

echo ""
echo "Total cluster pod usage: $total_used/$total_capacity"

echo ""
echo "7. Kubelet Feature Gates"
echo "----------------------"

# Try to detect kubelet feature gates
echo "Checking for kubelet feature gates..."

# This would require access to kubelet config or command line args
# We'll check for common feature indicators
features_detected=()

# Check for device plugins
device_plugins=$(kubectl get pods --all-namespaces -o json | jq '[.items[] | select(.metadata.name | contains("device-plugin"))] | length')
if [ "$device_plugins" -gt 0 ]; then
    features_detected+=("Device Plugins")
fi

# Check for CPU manager
cpu_manager_pods=$(kubectl get pods --all-namespaces -o json | jq '[.items[] | select(.spec.containers[].resources.requests.cpu | test("[0-9]+$"))] | length')
if [ "$cpu_manager_pods" -gt 0 ]; then
    features_detected+=("CPU Manager (possible)")
fi

if [ ${#features_detected[@]} -gt 0 ]; then
    echo "Detected features:"
    for feature in "${features_detected[@]}"; do
        echo "  - $feature"
    done
else
    echo "Unable to detect specific feature gates"
fi

echo ""
echo "8. Kubelet Health Endpoints"
echo "-------------------------"

# Check if we can access kubelet health endpoints
echo "Checking kubelet health endpoints..."

# We can't directly access kubelet endpoints from kubectl, but we can check for issues
unhealthy_nodes=0

for i in $(seq 0 $((total_nodes - 1))); do
    node=$(echo "$nodes" | jq ".items[$i]")
    node_name=$(echo "$node" | jq -r '.metadata.name')
    ready_status=$(echo "$node" | jq -r '.status.conditions[] | select(.type == "Ready") | .status')
    
    if [ "$ready_status" != "True" ]; then
        ((unhealthy_nodes++))
        echo -e "${RED}✗ Node $node_name: Kubelet appears unhealthy${NC}"
        
        # Get the reason
        ready_reason=$(echo "$node" | jq -r '.status.conditions[] | select(.type == "Ready") | .reason')
        ready_message=$(echo "$node" | jq -r '.status.conditions[] | select(.type == "Ready") | .message')
        
        echo "  Reason: $ready_reason"
        echo "  Message: $ready_message"
    fi
done

if [ "$unhealthy_nodes" -eq 0 ]; then
    echo -e "${GREEN}✓ All kubelet instances appear healthy${NC}"
fi

echo ""
echo "9. Container Runtime Integration"
echo "------------------------------"

# Check kubelet-runtime integration
echo "Checking container runtime integration..."

for i in $(seq 0 $((total_nodes - 1))); do
    node=$(echo "$nodes" | jq ".items[$i]")
    node_name=$(echo "$node" | jq -r '.metadata.name')
    runtime=$(echo "$node" | jq -r '.status.nodeInfo.containerRuntimeVersion')
    
    echo "Node $node_name: $runtime"
    
    # Check for runtime-specific issues
    runtime_type=$(echo "$runtime" | cut -d: -f1)
    
    case "$runtime_type" in
        "containerd")
            echo "  Runtime: containerd"
            ;;
        "docker")
            echo "  Runtime: Docker"
            echo -e "  ${YELLOW}⚠ Note: dockershim deprecated in K8s 1.24+${NC}"
            ;;
        "cri-o")
            echo "  Runtime: CRI-O"
            ;;
        *)
            echo "  Runtime: $runtime_type"
            ;;
    esac
done

echo ""
echo "10. Recommendations"
echo "-----------------"

recommendations=0

# Node health
if [ "$not_ready_nodes" -gt 0 ]; then
    echo -e "${RED}• Fix $not_ready_nodes NotReady node(s)${NC}"
    ((recommendations++))
fi

# Version consistency
if [ ${#kubelet_versions[@]} -gt 1 ]; then
    echo -e "${YELLOW}• Standardize kubelet versions across all nodes${NC}"
    ((recommendations++))
fi

# Resource pressure
if kubectl get nodes -o json | jq -e '.items[] | select(.status.conditions[] | select(.type == "MemoryPressure" and .status == "True"))' &> /dev/null; then
    echo -e "${YELLOW}• Address memory pressure on affected nodes${NC}"
    ((recommendations++))
fi

if kubectl get nodes -o json | jq -e '.items[] | select(.status.conditions[] | select(.type == "DiskPressure" and .status == "True"))' &> /dev/null; then
    echo -e "${YELLOW}• Address disk pressure on affected nodes${NC}"
    ((recommendations++))
fi

# Pod capacity
high_usage_nodes=$(kubectl get pods --all-namespaces -o json | jq -r '.items | group_by(.spec.nodeName) | map({node: .[0].spec.nodeName, count: length}) | .[] | select(.count > 100) | .node' | wc -l)
if [ "$high_usage_nodes" -gt 0 ]; then
    echo -e "${YELLOW}• Consider increasing pod capacity or adding nodes${NC}"
    ((recommendations++))
fi

# Events
if [ "${oom_kills:-0}" -gt 0 ]; then
    echo -e "${RED}• Investigate and fix OOM kills${NC}"
    ((recommendations++))
fi

if [ "${evictions:-0}" -gt 0 ]; then
    echo -e "${YELLOW}• Review pod resource requests/limits to prevent evictions${NC}"
    ((recommendations++))
fi

if [ "$recommendations" -eq 0 ]; then
    echo -e "${GREEN}✓ Kubelet configuration looks healthy!${NC}"
fi

echo ""
echo "======================================"
echo "Kubelet Health Check Complete"
echo ""
echo "Summary:"
echo "- Total nodes: $total_nodes"
echo "- Healthy nodes: $ready_nodes"
echo "- Unhealthy nodes: $((not_ready_nodes + unknown_nodes))"
echo "- Kubelet versions: ${#kubelet_versions[@]}"
echo "- Total pod capacity: $total_capacity"
echo "- Pods running: $total_used"
echo "- Recommendations: $recommendations"
echo "======================================"
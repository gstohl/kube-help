#!/bin/bash

# Host Port Bindings Check Script
# This script checks for potential host port conflicts that could prevent pod scheduling
# Host ports can cause pods to get stuck in Pending state if the port is already in use

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

echo "======================================"
echo "Kubernetes Host Port Bindings Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

echo "1. Scanning all pods for hostPort usage..."
echo "----------------------------------------"

# Get all pods with hostPort configurations
pods_with_hostport=$(kubectl get pods --all-namespaces -o json | jq -r '
    .items[] |
    select(.spec.containers[]?.ports[]?.hostPort != null) |
    {
        namespace: .metadata.namespace,
        name: .metadata.name,
        node: .spec.nodeName,
        status: .status.phase,
        containers: [
            .spec.containers[] |
            select(.ports[]?.hostPort != null) |
            {
                name: .name,
                ports: [
                    .ports[] |
                    select(.hostPort != null) |
                    {
                        containerPort: .containerPort,
                        hostPort: .hostPort,
                        protocol: (.protocol // "TCP"),
                        name: .name
                    }
                ]
            }
        ]
    }')

if [ -z "$pods_with_hostport" ]; then
    echo -e "${GREEN}✓ No pods using hostPort found${NC}"
else
    echo -e "${YELLOW}⚠ Found pods using hostPort:${NC}"
    echo ""
    
    # Process and display hostPort usage
    echo "$pods_with_hostport" | jq -r '
        "\(.namespace)/\(.name)",
        "  Node: \(.node // "not scheduled")",
        "  Status: \(.status)",
        (.containers[] | 
            "  Container: \(.name)",
            (.ports[] | 
                "    - Port \(.hostPort) (hostPort) -> \(.containerPort) (containerPort) \(.protocol)"
            )
        ),
        ""'
fi

echo "2. Checking for hostPort conflicts..."
echo "-----------------------------------"

# Group by node and check for conflicts
if [ -n "$pods_with_hostport" ]; then
    conflicts=$(echo "$pods_with_hostport" | jq -s '
        group_by(.node) |
        map({
            node: .[0].node,
            hostPorts: [
                .[] |
                .namespace as $ns |
                .name as $pod |
                .containers[].ports[] |
                {
                    namespace: $ns,
                    pod: $pod,
                    port: .hostPort,
                    protocol: .protocol
                }
            ] |
            group_by({port: .port, protocol: .protocol}) |
            map(select(length > 1)) |
            map({
                port: .[0].port,
                protocol: .[0].protocol,
                pods: map("\(.namespace)/\(.pod)")
            })
        }) |
        map(select(.hostPorts | length > 0))')
    
    if [ "$(echo "$conflicts" | jq '. | length')" -eq 0 ]; then
        echo -e "${GREEN}✓ No hostPort conflicts detected${NC}"
    else
        echo -e "${RED}✗ HostPort conflicts found:${NC}"
        echo "$conflicts" | jq -r '.[] | 
            "Node: \(.node)",
            (.hostPorts[] | 
                "  Port \(.port)/\(.protocol) used by multiple pods:",
                (.pods[] | "    - \(.)")
            ),
            ""'
    fi
fi

echo ""
echo "3. Checking pending pods that might be stuck due to hostPort..."
echo "-------------------------------------------------------------"

pending_pods=$(kubectl get pods --all-namespaces --field-selector=status.phase=Pending -o json)
pending_with_hostport=$(echo "$pending_pods" | jq -r '
    .items[] |
    select(.spec.containers[]?.ports[]?.hostPort != null) |
    "\(.metadata.namespace)/\(.metadata.name)"')

if [ -z "$pending_with_hostport" ]; then
    echo -e "${GREEN}✓ No pending pods with hostPort requirements${NC}"
else
    echo -e "${YELLOW}⚠ Pending pods with hostPort requirements:${NC}"
    echo "$pending_with_hostport"
    
    echo ""
    echo "Checking events for these pods..."
    for pod_info in $pending_with_hostport; do
        namespace=$(echo "$pod_info" | cut -d'/' -f1)
        pod=$(echo "$pod_info" | cut -d'/' -f2)
        
        echo -e "${BLUE}$pod_info:${NC}"
        events=$(kubectl get events -n "$namespace" --field-selector involvedObject.name="$pod" -o json | jq -r '
            .items[] |
            select(.reason == "FailedScheduling") |
            .message' | tail -n 1)
        
        if [ -n "$events" ]; then
            echo "  $events"
        else
            echo "  No scheduling events found"
        fi
    done
fi

echo ""
echo "4. Analyzing hostPort usage by node..."
echo "------------------------------------"

nodes=$(kubectl get nodes -o json | jq -r '.items[].metadata.name')
for node in $nodes; do
    echo -e "${BLUE}Node: $node${NC}"
    
    # Get all hostPorts used on this node
    hostports_on_node=$(kubectl get pods --all-namespaces --field-selector spec.nodeName="$node" -o json | jq -r '
        [
            .items[] |
            select(.spec.containers[]?.ports[]?.hostPort != null) |
            .spec.containers[].ports[] |
            select(.hostPort != null) |
            {
                port: .hostPort,
                protocol: (.protocol // "TCP")
            }
        ] |
        unique |
        sort_by(.port) |
        .[] |
        "\(.port)/\(.protocol)"')
    
    if [ -z "$hostports_on_node" ]; then
        echo "  No hostPorts in use"
    else
        echo "  HostPorts in use:"
        echo "$hostports_on_node" | sed 's/^/    - /'
    fi
    echo ""
done

echo "5. Common hostPort ranges and recommendations..."
echo "----------------------------------------------"

# Check for common service ports
common_ports=$(echo "$pods_with_hostport" | jq -r '
    .containers[].ports[].hostPort' | sort -n | uniq -c | sort -rn)

if [ -n "$common_ports" ]; then
    echo "Most used hostPorts:"
    echo "$common_ports" | head -10 | while read count port; do
        echo "  - Port $port: used $count time(s)"
        
        # Provide recommendations for common ports
        case $port in
            80|8080)
                echo -e "    ${YELLOW}→ Consider using Ingress instead of hostPort 80/8080${NC}"
                ;;
            443|8443)
                echo -e "    ${YELLOW}→ Consider using Ingress with TLS instead of hostPort 443/8443${NC}"
                ;;
            22)
                echo -e "    ${RED}→ Warning: SSH port exposure - security risk${NC}"
                ;;
            3306|5432|6379|27017)
                echo -e "    ${YELLOW}→ Database ports - consider using ClusterIP service instead${NC}"
                ;;
        esac
    done
fi

echo ""
echo "6. DaemonSets with hostPort..."
echo "-----------------------------"

daemonsets_with_hostport=$(kubectl get daemonsets --all-namespaces -o json | jq -r '
    .items[] |
    select(.spec.template.spec.containers[]?.ports[]?.hostPort != null) |
    {
        namespace: .metadata.namespace,
        name: .metadata.name,
        hostPorts: [
            .spec.template.spec.containers[].ports[] |
            select(.hostPort != null) |
            "\(.hostPort)/\(.protocol // "TCP")"
        ]
    } |
    "\(.namespace)/\(.name): \(.hostPorts | join(", "))"')

if [ -z "$daemonsets_with_hostport" ]; then
    echo -e "${GREEN}✓ No DaemonSets using hostPort${NC}"
else
    echo -e "${MAGENTA}DaemonSets with hostPort (expected on all nodes):${NC}"
    echo "$daemonsets_with_hostport"
fi

echo ""
echo "7. Recommendations..."
echo "-------------------"

total_hostport_pods=$(echo "$pods_with_hostport" | jq -s '. | length')

if [ "$total_hostport_pods" -eq 0 ]; then
    echo -e "${GREEN}✓ No hostPort usage detected - good practice!${NC}"
else
    echo -e "${YELLOW}Found $total_hostport_pods pod(s) using hostPort${NC}"
    echo ""
    echo "Best practices:"
    echo "1. Use NodePort or LoadBalancer services instead of hostPort"
    echo "2. Use Ingress controllers for HTTP/HTTPS traffic"
    echo "3. Only use hostPort for system-level DaemonSets when absolutely necessary"
    echo "4. Consider using hostNetwork instead of hostPort for system pods"
    echo "5. Document all hostPort usage and ensure no conflicts"
    
    # Check if there are non-DaemonSet pods using hostPort
    non_ds_hostport=$(kubectl get pods --all-namespaces -o json | jq -r '
        .items[] |
        select(.spec.containers[]?.ports[]?.hostPort != null) |
        select(.metadata.ownerReferences[0].kind != "DaemonSet") |
        .metadata.name' | wc -l)
    
    if [ "$non_ds_hostport" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}⚠ Warning: Found $non_ds_hostport non-DaemonSet pod(s) using hostPort${NC}"
        echo "   This can limit pod scheduling flexibility"
    fi
fi

echo ""
echo "======================================"
echo "Host Port Check Complete"
echo "======================================"
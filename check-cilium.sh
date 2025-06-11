#!/bin/bash

# Cilium CNI Health Check Script
# This script checks the health status of Cilium Container Network Interface

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

echo "======================================"
echo "Cilium CNI Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

# Check if Cilium CLI is available
CILIUM_CLI_AVAILABLE=false
if command -v cilium &> /dev/null; then
    CILIUM_CLI_AVAILABLE=true
    echo -e "${GREEN}✓ Cilium CLI found${NC}"
else
    echo -e "${YELLOW}⚠ Cilium CLI not found. Some checks will be limited.${NC}"
    echo "  Install with: curl -L --remote-name-all https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz"
fi

# Find Cilium namespace (usually kube-system)
NAMESPACE="kube-system"
if ! kubectl get pods -n "$NAMESPACE" -l k8s-app=cilium &> /dev/null; then
    # Try cilium namespace
    if kubectl get namespace cilium &> /dev/null && kubectl get pods -n cilium -l k8s-app=cilium &> /dev/null; then
        NAMESPACE="cilium"
    else
        echo -e "${RED}Error: Cilium not found in kube-system or cilium namespace${NC}"
        exit 1
    fi
fi

echo -e "${BLUE}Found Cilium in namespace: $NAMESPACE${NC}"
echo ""

echo "1. Cilium Agent (DaemonSet) Status..."
echo "------------------------------------"

cilium_ds=$(kubectl get daemonset -n "$NAMESPACE" cilium -o json 2>/dev/null)
if [ -z "$cilium_ds" ] || [ "$cilium_ds" = "null" ]; then
    echo -e "${RED}✗ Cilium DaemonSet not found${NC}"
    exit 1
fi

desired=$(echo "$cilium_ds" | jq '.status.desiredNumberScheduled')
ready=$(echo "$cilium_ds" | jq '.status.numberReady // 0')
available=$(echo "$cilium_ds" | jq '.status.numberAvailable // 0')

echo "Cilium DaemonSet:"
if [ "$ready" -eq "$desired" ]; then
    echo -e "${GREEN}✓ All nodes have Cilium running: $ready/$desired${NC}"
else
    echo -e "${YELLOW}⚠ Only $ready/$desired nodes have Cilium running${NC}"
    echo "Problematic nodes:"
    kubectl get pods -n "$NAMESPACE" -l k8s-app=cilium -o wide | grep -v Running || true
fi

# Check Cilium pod details
echo ""
echo "Cilium Pod Status:"
cilium_pods=$(kubectl get pods -n "$NAMESPACE" -l k8s-app=cilium -o json)
pod_count=$(echo "$cilium_pods" | jq '.items | length')
running_count=$(echo "$cilium_pods" | jq '[.items[] | select(.status.phase == "Running")] | length')
restart_counts=$(echo "$cilium_pods" | jq -r '.items[] | select((.status.containerStatuses[0].restartCount // 0) > 0) | "\(.metadata.name): \(.status.containerStatuses[0].restartCount) restarts"')

echo "Total Cilium pods: $pod_count"
echo "Running pods: $running_count"
if [ -n "$restart_counts" ]; then
    echo -e "${YELLOW}Pods with restarts:${NC}"
    echo "$restart_counts"
fi

echo ""
echo "2. Cilium Operator Status..."
echo "--------------------------"

operator_deployment=$(kubectl get deployment -n "$NAMESPACE" cilium-operator -o json 2>/dev/null)
if [ -n "$operator_deployment" ] && [ "$operator_deployment" != "null" ]; then
    replicas=$(echo "$operator_deployment" | jq '.spec.replicas')
    ready_replicas=$(echo "$operator_deployment" | jq '.status.readyReplicas // 0')
    
    if [ "$ready_replicas" -eq "$replicas" ]; then
        echo -e "${GREEN}✓ Cilium Operator: $ready_replicas/$replicas replicas ready${NC}"
    else
        echo -e "${YELLOW}⚠ Cilium Operator: $ready_replicas/$replicas replicas ready${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Cilium Operator deployment not found${NC}"
fi

echo ""
echo "3. Cilium Configuration..."
echo "------------------------"

# Check Cilium ConfigMap
config_map=$(kubectl get configmap -n "$NAMESPACE" cilium-config -o json 2>/dev/null)
if [ -n "$config_map" ] && [ "$config_map" != "null" ]; then
    echo "Key configuration parameters:"
    
    # Extract important configs
    tunnel_mode=$(echo "$config_map" | jq -r '.data.tunnel // "vxlan"')
    ipam_mode=$(echo "$config_map" | jq -r '.data.ipam // "cluster-pool"')
    enable_ipv4=$(echo "$config_map" | jq -r '.data."enable-ipv4" // "true"')
    enable_ipv6=$(echo "$config_map" | jq -r '.data."enable-ipv6" // "false"')
    kube_proxy_replacement=$(echo "$config_map" | jq -r '.data."kube-proxy-replacement" // "disabled"')
    enable_hubble=$(echo "$config_map" | jq -r '.data."enable-hubble" // "false"')
    
    echo "  - Tunnel mode: $tunnel_mode"
    echo "  - IPAM mode: $ipam_mode"
    echo "  - IPv4 enabled: $enable_ipv4"
    echo "  - IPv6 enabled: $enable_ipv6"
    echo "  - Kube-proxy replacement: $kube_proxy_replacement"
    echo "  - Hubble enabled: $enable_hubble"
else
    echo -e "${YELLOW}⚠ Cilium ConfigMap not found${NC}"
fi

echo ""
echo "4. Cilium Health Checks..."
echo "------------------------"

if [ "$CILIUM_CLI_AVAILABLE" = true ]; then
    echo "Running Cilium CLI status check..."
    cilium status --namespace "$NAMESPACE" --wait=false || echo -e "${YELLOW}⚠ Cilium CLI status check failed${NC}"
else
    # Manual health checks
    echo "Running manual health checks..."
    
    # Get a cilium pod for exec
    first_cilium_pod=$(echo "$cilium_pods" | jq -r '.items[0].metadata.name')
    
    if [ -n "$first_cilium_pod" ] && [ "$first_cilium_pod" != "null" ]; then
        # Check cilium status
        echo -n "Cilium agent status: "
        if kubectl exec -n "$NAMESPACE" "$first_cilium_pod" -- cilium status --brief &> /dev/null; then
            echo -e "${GREEN}✓ Healthy${NC}"
        else
            echo -e "${YELLOW}⚠ Check failed${NC}"
        fi
        
        # Check cilium health
        echo -n "Cilium connectivity health: "
        health_status=$(kubectl exec -n "$NAMESPACE" "$first_cilium_pod" -- cilium-health status 2>/dev/null || echo "failed")
        if echo "$health_status" | grep -q "Probe succeeded"; then
            echo -e "${GREEN}✓ All probes succeeded${NC}"
        else
            echo -e "${YELLOW}⚠ Some health probes may have failed${NC}"
        fi
    fi
fi

echo ""
echo "5. Cilium Network Policies..."
echo "---------------------------"

# Check CiliumNetworkPolicies
cnp_count=$(kubectl get ciliumnetworkpolicies --all-namespaces -o json 2>/dev/null | jq '.items | length' || echo "0")
echo "CiliumNetworkPolicies: $cnp_count"

# Check CiliumClusterwideNetworkPolicies
ccnp_count=$(kubectl get ciliumclusterwidenetworkpolicies -o json 2>/dev/null | jq '.items | length' || echo "0")
echo "CiliumClusterwideNetworkPolicies: $ccnp_count"

# Check regular NetworkPolicies
np_count=$(kubectl get networkpolicies --all-namespaces -o json | jq '.items | length')
echo "Kubernetes NetworkPolicies: $np_count"

echo ""
echo "6. Cilium Endpoints..."
echo "--------------------"

# Check CiliumEndpoints
endpoints=$(kubectl get ciliumendpoints --all-namespaces -o json 2>/dev/null)
if [ -n "$endpoints" ] && [ "$endpoints" != "null" ]; then
    total_endpoints=$(echo "$endpoints" | jq '.items | length')
    ready_endpoints=$(echo "$endpoints" | jq '[.items[] | select(.status.state == "ready")] | length' 2>/dev/null || echo "0")
    
    echo "Total Cilium endpoints: $total_endpoints"
    if [ "$ready_endpoints" -eq "$total_endpoints" ]; then
        echo -e "${GREEN}✓ All endpoints ready: $ready_endpoints/$total_endpoints${NC}"
    else
        echo -e "${YELLOW}⚠ Ready endpoints: $ready_endpoints/$total_endpoints${NC}"
        
        # Show problematic endpoints
        not_ready=$(echo "$endpoints" | jq -r '.items[] | select(.status.state != "ready") | "\(.metadata.namespace)/\(.metadata.name): \(.status.state)"' 2>/dev/null)
        if [ -n "$not_ready" ]; then
            echo "Not ready endpoints:"
            echo "$not_ready" | head -10
        fi
    fi
else
    echo -e "${YELLOW}⚠ Unable to check Cilium endpoints${NC}"
fi

echo ""
echo "7. IP Address Management (IPAM)..."
echo "--------------------------------"

if [ -n "$first_cilium_pod" ] && [ "$first_cilium_pod" != "null" ]; then
    echo "IPAM Status:"
    ipam_status=$(kubectl exec -n "$NAMESPACE" "$first_cilium_pod" -- cilium endpoint list -o json 2>/dev/null | jq 'length' || echo "0")
    echo "  Endpoints with IPs allocated: $ipam_status"
    
    # Check for IP allocation issues
    allocation_errors=$(kubectl logs -n "$NAMESPACE" "$first_cilium_pod" --tail=100 2>/dev/null | grep -i "ipam" | grep -i "error" | wc -l || echo "0")
    if [ "$allocation_errors" -gt 0 ]; then
        echo -e "${YELLOW}⚠ Found $allocation_errors IPAM-related errors in recent logs${NC}"
    else
        echo -e "${GREEN}✓ No IPAM errors in recent logs${NC}"
    fi
fi

echo ""
echo "8. Hubble Observability (if enabled)..."
echo "-------------------------------------"

# Check if Hubble is deployed
hubble_relay=$(kubectl get deployment -n "$NAMESPACE" hubble-relay -o json 2>/dev/null)
if [ -n "$hubble_relay" ] && [ "$hubble_relay" != "null" ]; then
    relay_replicas=$(echo "$hubble_relay" | jq '.spec.replicas')
    relay_ready=$(echo "$hubble_relay" | jq '.status.readyReplicas // 0')
    
    echo -e "${GREEN}✓ Hubble Relay found${NC}"
    if [ "$relay_ready" -eq "$relay_replicas" ]; then
        echo -e "${GREEN}✓ Hubble Relay: $relay_ready/$relay_replicas replicas ready${NC}"
    else
        echo -e "${YELLOW}⚠ Hubble Relay: $relay_ready/$relay_replicas replicas ready${NC}"
    fi
    
    # Check Hubble UI
    hubble_ui=$(kubectl get deployment -n "$NAMESPACE" hubble-ui -o json 2>/dev/null)
    if [ -n "$hubble_ui" ] && [ "$hubble_ui" != "null" ]; then
        echo -e "${GREEN}✓ Hubble UI deployed${NC}"
    fi
else
    echo "Hubble not deployed (optional observability component)"
fi

echo ""
echo "9. Cilium Node Status..."
echo "-----------------------"

# Check CiliumNodes
cilium_nodes=$(kubectl get ciliumnodes -o json 2>/dev/null)
if [ -n "$cilium_nodes" ] && [ "$cilium_nodes" != "null" ]; then
    total_nodes=$(echo "$cilium_nodes" | jq '.items | length')
    echo "Cilium nodes registered: $total_nodes"
    
    # Check for encryption if enabled
    encryption_enabled=$(echo "$cilium_nodes" | jq '[.items[] | select(.spec.encryption.type != null)] | length')
    if [ "$encryption_enabled" -gt 0 ]; then
        echo -e "${GREEN}✓ Encryption enabled on $encryption_enabled nodes${NC}"
    fi
    
    # Check node health
    echo ""
    echo "Node health summary:"
    echo "$cilium_nodes" | jq -r '.items[] | "\(.metadata.name): \(.status.ipam.operator-status.error // "OK")"' | head -10
else
    echo -e "${YELLOW}⚠ Unable to check Cilium nodes${NC}"
fi

echo ""
echo "10. Recent Cilium Events..."
echo "-------------------------"

# Check for Cilium-related events
cilium_events=$(kubectl get events --all-namespaces --field-selector reason=CiliumAgent -o json 2>/dev/null | jq '.items | length' || echo "0")
if [ "$cilium_events" -gt 0 ]; then
    echo "Recent Cilium events found: $cilium_events"
    kubectl get events --all-namespaces --field-selector reason=CiliumAgent --sort-by='.lastTimestamp' | tail -5
fi

# Check Cilium agent logs for errors
if [ -n "$first_cilium_pod" ] && [ "$first_cilium_pod" != "null" ]; then
    echo ""
    echo "Recent errors in Cilium logs:"
    errors=$(kubectl logs -n "$NAMESPACE" "$first_cilium_pod" --tail=100 2>/dev/null | grep -E "level=(error|fatal)" | tail -5)
    if [ -n "$errors" ]; then
        echo -e "${YELLOW}Recent errors found:${NC}"
        echo "$errors"
    else
        echo -e "${GREEN}✓ No recent errors in logs${NC}"
    fi
fi

echo ""
echo "======================================"
echo "Cilium CNI Health Check Complete"
echo ""
echo "Summary:"
echo "- Cilium agents: $ready/$desired nodes"
echo "- Endpoints: $total_endpoints total"
echo "- Network policies: $cnp_count Cilium, $np_count Kubernetes"
echo "======================================"
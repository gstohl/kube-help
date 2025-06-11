#!/bin/bash

# Cilium Envoy Health Check Script
# This script checks the health of Envoy proxies managed by Cilium

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

echo "======================================"
echo "Cilium Envoy Proxy Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

# Find Cilium namespace
NAMESPACE="kube-system"
if ! kubectl get pods -n "$NAMESPACE" -l k8s-app=cilium &> /dev/null; then
    if kubectl get namespace cilium &> /dev/null && kubectl get pods -n cilium -l k8s-app=cilium &> /dev/null; then
        NAMESPACE="cilium"
    else
        echo -e "${RED}Error: Cilium not found in kube-system or cilium namespace${NC}"
        exit 1
    fi
fi

echo -e "${BLUE}Checking Cilium Envoy in namespace: $NAMESPACE${NC}"
echo ""

# Check if Cilium is using Envoy
echo "1. Checking Cilium Envoy Configuration..."
echo "---------------------------------------"

cilium_config=$(kubectl get configmap -n "$NAMESPACE" cilium-config -o json 2>/dev/null)
if [ -n "$cilium_config" ] && [ "$cilium_config" != "null" ]; then
    # Check if L7 proxy is enabled
    enable_l7_proxy=$(echo "$cilium_config" | jq -r '.data."enable-l7-proxy" // "true"')
    enable_envoy_config=$(echo "$cilium_config" | jq -r '.data."enable-envoy-config" // "false"')
    
    echo "L7 Proxy enabled: $enable_l7_proxy"
    echo "Envoy config enabled: $enable_envoy_config"
    
    if [ "$enable_l7_proxy" != "true" ]; then
        echo -e "${YELLOW}⚠ L7 proxy is disabled. Envoy may not be in use.${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Unable to check Cilium configuration${NC}"
fi

echo ""
echo "2. Checking Envoy Processes in Cilium Pods..."
echo "-------------------------------------------"

# Get all Cilium pods
cilium_pods=$(kubectl get pods -n "$NAMESPACE" -l k8s-app=cilium -o json)
total_cilium_pods=$(echo "$cilium_pods" | jq '.items | length')
pods_with_envoy=0
envoy_issues=0

echo "Scanning $total_cilium_pods Cilium pods for Envoy processes..."
echo ""

# Check each Cilium pod for Envoy
for i in $(seq 0 $((total_cilium_pods - 1))); do
    pod_name=$(echo "$cilium_pods" | jq -r ".items[$i].metadata.name")
    node_name=$(echo "$cilium_pods" | jq -r ".items[$i].spec.nodeName")
    
    # Check if Envoy process is running
    envoy_count=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- sh -c 'ps aux | grep -c "[c]ilium-envoy"' 2>/dev/null || echo "0")
    
    if [ "$envoy_count" -gt 0 ]; then
        pods_with_envoy=$((pods_with_envoy + 1))
        echo -e "${GREEN}✓ $pod_name (node: $node_name): $envoy_count Envoy process(es)${NC}"
        
        # Check Envoy admin interface
        if kubectl exec -n "$NAMESPACE" "$pod_name" -- curl -s http://localhost:9901/stats/prometheus &> /dev/null; then
            echo "  └─ Envoy admin interface: accessible"
        else
            echo -e "  └─ Envoy admin interface: ${YELLOW}not accessible${NC}"
            envoy_issues=$((envoy_issues + 1))
        fi
    else
        echo -e "${YELLOW}⚠ $pod_name (node: $node_name): No Envoy process found${NC}"
    fi
done

echo ""
echo "Summary: $pods_with_envoy/$total_cilium_pods pods have Envoy running"

echo ""
echo "3. Checking Envoy Listeners and Clusters..."
echo "-----------------------------------------"

# Get a pod with Envoy for detailed checks
pod_with_envoy=""
for i in $(seq 0 $((total_cilium_pods - 1))); do
    pod_name=$(echo "$cilium_pods" | jq -r ".items[$i].metadata.name")
    if kubectl exec -n "$NAMESPACE" "$pod_name" -- sh -c 'ps aux | grep -q "[c]ilium-envoy"' 2>/dev/null; then
        pod_with_envoy="$pod_name"
        break
    fi
done

if [ -n "$pod_with_envoy" ]; then
    echo "Using pod $pod_with_envoy for detailed Envoy checks..."
    
    # Check listeners
    echo ""
    echo "Active Envoy Listeners:"
    listeners=$(kubectl exec -n "$NAMESPACE" "$pod_with_envoy" -- curl -s http://localhost:9901/listeners 2>/dev/null || echo "")
    if [ -n "$listeners" ]; then
        listener_count=$(echo "$listeners" | grep -c ":" || echo "0")
        echo -e "${GREEN}✓ Found $listener_count active listeners${NC}"
        echo "$listeners" | head -10
    else
        echo -e "${YELLOW}⚠ Unable to retrieve listener information${NC}"
    fi
    
    # Check clusters
    echo ""
    echo "Active Envoy Clusters:"
    clusters=$(kubectl exec -n "$NAMESPACE" "$pod_with_envoy" -- curl -s http://localhost:9901/clusters 2>/dev/null || echo "")
    if [ -n "$clusters" ]; then
        cluster_count=$(echo "$clusters" | grep -c "::observability_name::" || echo "0")
        echo -e "${GREEN}✓ Found $cluster_count active clusters${NC}"
    else
        echo -e "${YELLOW}⚠ Unable to retrieve cluster information${NC}"
    fi
else
    echo -e "${YELLOW}⚠ No Cilium pod with Envoy found for detailed checks${NC}"
fi

echo ""
echo "4. Checking Envoy Statistics..."
echo "-----------------------------"

if [ -n "$pod_with_envoy" ]; then
    # Get key statistics
    stats=$(kubectl exec -n "$NAMESPACE" "$pod_with_envoy" -- curl -s http://localhost:9901/stats/prometheus 2>/dev/null || echo "")
    
    if [ -n "$stats" ]; then
        # Extract key metrics
        connections=$(echo "$stats" | grep "envoy_http_downstream_cx_total" | tail -1 | awk '{print $2}' || echo "0")
        requests=$(echo "$stats" | grep "envoy_http_downstream_rq_total" | tail -1 | awk '{print $2}' || echo "0")
        active_connections=$(echo "$stats" | grep "envoy_http_downstream_cx_active" | tail -1 | awk '{print $2}' || echo "0")
        
        echo "Envoy Statistics:"
        echo "  Total connections: ${connections:-0}"
        echo "  Total requests: ${requests:-0}"
        echo "  Active connections: ${active_connections:-0}"
        
        # Check for errors
        cx_errors=$(echo "$stats" | grep "envoy_http_downstream_cx_destroy_remote_with_active_rq" | tail -1 | awk '{print $2}' || echo "0")
        rq_errors=$(echo "$stats" | grep "envoy_http_downstream_rq_xx" | grep "5xx" | tail -1 | awk '{print $2}' || echo "0")
        
        if [ "${cx_errors:-0}" != "0" ] || [ "${rq_errors:-0}" != "0" ]; then
            echo -e "${YELLOW}⚠ Errors detected:${NC}"
            [ "${cx_errors:-0}" != "0" ] && echo "    Connection errors: $cx_errors"
            [ "${rq_errors:-0}" != "0" ] && echo "    5xx responses: $rq_errors"
        else
            echo -e "${GREEN}✓ No connection errors detected${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ Unable to retrieve Envoy statistics${NC}"
    fi
fi

echo ""
echo "5. Checking L7 Network Policies..."
echo "--------------------------------"

# Check for L7 policies
l7_policies=$(kubectl get ciliumnetworkpolicies --all-namespaces -o json 2>/dev/null | jq '[.items[] | select(.spec.specs[]?.l7Rules != null or .spec.specs[]?.rules[]?.toPorts[]?.rules != null)] | length' || echo "0")
l7_clusterwide=$(kubectl get ciliumclusterwidenetworkpolicies -o json 2>/dev/null | jq '[.items[] | select(.spec.specs[]?.l7Rules != null or .spec.specs[]?.rules[]?.toPorts[]?.rules != null)] | length' || echo "0")

total_l7_policies=$((l7_policies + l7_clusterwide))

if [ "$total_l7_policies" -gt 0 ]; then
    echo -e "${GREEN}✓ Found $total_l7_policies L7 network policies${NC}"
    echo "  - Namespace policies with L7 rules: $l7_policies"
    echo "  - Clusterwide policies with L7 rules: $l7_clusterwide"
    
    # Show some L7 policy details
    echo ""
    echo "L7 Policy Examples:"
    kubectl get ciliumnetworkpolicies --all-namespaces -o json 2>/dev/null | jq -r '
        .items[] | 
        select(.spec.specs[]?.l7Rules != null or .spec.specs[]?.rules[]?.toPorts[]?.rules != null) |
        "\(.metadata.namespace)/\(.metadata.name)"' | head -5
else
    echo "No L7 network policies found (Envoy may not be actively used)"
fi

echo ""
echo "6. Checking Envoy Configuration Sources..."
echo "---------------------------------------"

if [ -n "$pod_with_envoy" ]; then
    # Check for Envoy config
    echo -n "Envoy bootstrap configuration: "
    if kubectl exec -n "$NAMESPACE" "$pod_with_envoy" -- test -f /var/run/cilium/envoy/bootstrap-config.json 2>/dev/null; then
        echo -e "${GREEN}✓ Found${NC}"
    else
        echo -e "${YELLOW}⚠ Not found at expected location${NC}"
    fi
    
    # Check for xDS socket
    echo -n "Envoy xDS socket: "
    if kubectl exec -n "$NAMESPACE" "$pod_with_envoy" -- test -e /var/run/cilium/envoy/sds.sock 2>/dev/null; then
        echo -e "${GREEN}✓ Found${NC}"
    else
        echo -e "${YELLOW}⚠ Not found${NC}"
    fi
fi

echo ""
echo "7. Checking Envoy Resource Usage..."
echo "---------------------------------"

if [ -n "$pod_with_envoy" ]; then
    # Get Envoy process resource usage
    envoy_resources=$(kubectl exec -n "$NAMESPACE" "$pod_with_envoy" -- sh -c 'ps aux | grep "[c]ilium-envoy" | head -1' 2>/dev/null || echo "")
    
    if [ -n "$envoy_resources" ]; then
        cpu_usage=$(echo "$envoy_resources" | awk '{print $3}')
        mem_usage=$(echo "$envoy_resources" | awk '{print $4}')
        vsz=$(echo "$envoy_resources" | awk '{print $5}')
        rss=$(echo "$envoy_resources" | awk '{print $6}')
        
        echo "Envoy Process Resources:"
        echo "  CPU Usage: ${cpu_usage}%"
        echo "  Memory Usage: ${mem_usage}%"
        echo "  Virtual Memory: $((vsz / 1024)) MB"
        echo "  Resident Memory: $((rss / 1024)) MB"
    fi
fi

echo ""
echo "8. Checking Recent Envoy Logs..."
echo "------------------------------"

if [ -n "$pod_with_envoy" ]; then
    # Check Cilium logs for Envoy-related messages
    envoy_logs=$(kubectl logs -n "$NAMESPACE" "$pod_with_envoy" --tail=200 2>/dev/null | grep -i envoy | tail -10)
    
    if [ -n "$envoy_logs" ]; then
        echo "Recent Envoy-related log entries:"
        echo "$envoy_logs"
        
        # Check for errors
        error_count=$(echo "$envoy_logs" | grep -ci "error\|fail" || echo "0")
        if [ "$error_count" -gt 0 ]; then
            echo -e "${YELLOW}⚠ Found $error_count error messages in recent Envoy logs${NC}"
        fi
    else
        echo "No recent Envoy-related logs found"
    fi
fi

echo ""
echo "9. Checking Envoy Version..."
echo "--------------------------"

if [ -n "$pod_with_envoy" ]; then
    envoy_version=$(kubectl exec -n "$NAMESPACE" "$pod_with_envoy" -- cilium-envoy --version 2>/dev/null | head -1 || echo "")
    
    if [ -n "$envoy_version" ]; then
        echo "Envoy version: $envoy_version"
    else
        echo -e "${YELLOW}⚠ Unable to determine Envoy version${NC}"
    fi
fi

echo ""
echo "10. Recommendations..."
echo "--------------------"

if [ "$pods_with_envoy" -eq 0 ]; then
    echo -e "${YELLOW}No Envoy processes found. This could mean:${NC}"
    echo "1. L7 proxy is disabled in Cilium configuration"
    echo "2. No L7 network policies are currently active"
    echo "3. Cilium is running in a mode that doesn't require Envoy"
elif [ "$envoy_issues" -gt 0 ]; then
    echo -e "${YELLOW}Some Envoy instances have issues:${NC}"
    echo "1. Check Cilium agent logs for Envoy-related errors"
    echo "2. Verify L7 network policies are correctly configured"
    echo "3. Ensure sufficient resources are available for Envoy"
else
    echo -e "${GREEN}✓ Envoy appears to be functioning correctly${NC}"
fi

echo ""
echo "======================================"
echo "Cilium Envoy Health Check Complete"
echo ""
echo "Summary:"
echo "- Cilium pods with Envoy: $pods_with_envoy/$total_cilium_pods"
echo "- L7 policies configured: $total_l7_policies"
[ "$envoy_issues" -gt 0 ] && echo -e "- ${YELLOW}Issues detected: $envoy_issues${NC}"
echo "======================================"
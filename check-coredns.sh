#!/bin/bash

# CoreDNS Health Check Script
# This script checks the health status of CoreDNS - Kubernetes' DNS service

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

echo "======================================"
echo "CoreDNS Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

# Find CoreDNS namespace and deployment
NAMESPACE="kube-system"
COREDNS_LABEL="k8s-app=kube-dns"
COREDNS_NAME="coredns"

# Some clusters might use different labels
if ! kubectl get pods -n "$NAMESPACE" -l "$COREDNS_LABEL" &> /dev/null; then
    COREDNS_LABEL="app=coredns"
    if ! kubectl get pods -n "$NAMESPACE" -l "$COREDNS_LABEL" &> /dev/null; then
        echo -e "${RED}Error: CoreDNS not found in $NAMESPACE namespace${NC}"
        exit 1
    fi
fi

echo -e "${BLUE}Found CoreDNS in namespace: $NAMESPACE${NC}"
echo ""

echo "1. CoreDNS Deployment Status..."
echo "-----------------------------"

# Get deployment info
deployment=$(kubectl get deployment -n "$NAMESPACE" "$COREDNS_NAME" -o json 2>/dev/null || \
             kubectl get deployment -n "$NAMESPACE" -l "$COREDNS_LABEL" -o json 2>/dev/null | jq '.items[0]')

if [ -n "$deployment" ] && [ "$deployment" != "null" ]; then
    replicas=$(echo "$deployment" | jq '.spec.replicas')
    ready_replicas=$(echo "$deployment" | jq '.status.readyReplicas // 0')
    available_replicas=$(echo "$deployment" | jq '.status.availableReplicas // 0')
    
    echo "CoreDNS Deployment:"
    if [ "$ready_replicas" -eq "$replicas" ]; then
        echo -e "${GREEN}✓ All replicas ready: $ready_replicas/$replicas${NC}"
    else
        echo -e "${YELLOW}⚠ Only $ready_replicas/$replicas replicas ready${NC}"
    fi
    echo "  Available replicas: $available_replicas"
    
    # Check deployment conditions
    conditions=$(echo "$deployment" | jq -r '.status.conditions[]? | "\(.type): \(.status)"')
    if [ -n "$conditions" ]; then
        echo "  Conditions:"
        echo "$conditions" | sed 's/^/    /'
    fi
else
    echo -e "${RED}✗ CoreDNS deployment not found${NC}"
fi

echo ""
echo "2. CoreDNS Pod Health..."
echo "----------------------"

# Get CoreDNS pods
coredns_pods=$(kubectl get pods -n "$NAMESPACE" -l "$COREDNS_LABEL" -o json)
pod_count=$(echo "$coredns_pods" | jq '.items | length')
running_count=$(echo "$coredns_pods" | jq '[.items[] | select(.status.phase == "Running")] | length')

echo "Total CoreDNS pods: $pod_count"
if [ "$running_count" -eq "$pod_count" ]; then
    echo -e "${GREEN}✓ All pods running: $running_count/$pod_count${NC}"
else
    echo -e "${YELLOW}⚠ Only $running_count/$pod_count pods running${NC}"
fi

# Show pod details
echo ""
echo "Pod details:"
echo "$coredns_pods" | jq -r '.items[] | 
    "\(.metadata.name):" +
    "\n  Node: \(.spec.nodeName)" +
    "\n  Status: \(.status.phase)" +
    "\n  Ready: \(if .status.conditions[] | select(.type == "Ready") | .status == "True" then "Yes" else "No" end)" +
    "\n  Restarts: \(.status.containerStatuses[0].restartCount // 0)"'

# Check for high restart counts
high_restart_pods=$(echo "$coredns_pods" | jq -r '.items[] | select(.status.containerStatuses[0].restartCount > 5) | "\(.metadata.name): \(.status.containerStatuses[0].restartCount) restarts"')
if [ -n "$high_restart_pods" ]; then
    echo ""
    echo -e "${YELLOW}⚠ Pods with high restart counts:${NC}"
    echo "$high_restart_pods"
fi

echo ""
echo "3. CoreDNS Service Configuration..."
echo "---------------------------------"

# Check CoreDNS service
dns_service=$(kubectl get service -n "$NAMESPACE" kube-dns -o json 2>/dev/null)
if [ -n "$dns_service" ] && [ "$dns_service" != "null" ]; then
    cluster_ip=$(echo "$dns_service" | jq -r '.spec.clusterIP')
    echo -e "${GREEN}✓ DNS Service found${NC}"
    echo "  ClusterIP: $cluster_ip"
    echo "  Ports:"
    echo "$dns_service" | jq -r '.spec.ports[] | "    - \(.name): \(.port)/\(.protocol)"'
    
    # Check endpoints
    endpoints=$(kubectl get endpoints -n "$NAMESPACE" kube-dns -o json | jq '.subsets[0].addresses | length' 2>/dev/null || echo "0")
    echo "  Active endpoints: $endpoints"
else
    echo -e "${RED}✗ kube-dns service not found${NC}"
fi

echo ""
echo "4. CoreDNS Configuration..."
echo "------------------------"

# Check CoreDNS ConfigMap
configmap=$(kubectl get configmap -n "$NAMESPACE" coredns -o json 2>/dev/null)
if [ -n "$configmap" ] && [ "$configmap" != "null" ]; then
    echo -e "${GREEN}✓ CoreDNS ConfigMap found${NC}"
    
    # Extract Corefile content
    corefile=$(echo "$configmap" | jq -r '.data.Corefile')
    
    # Check for key plugins
    echo ""
    echo "Configured plugins:"
    [ -n "$(echo "$corefile" | grep -E "^\s*kubernetes")" ] && echo "  ✓ kubernetes - Kubernetes service discovery"
    [ -n "$(echo "$corefile" | grep -E "^\s*forward")" ] && echo "  ✓ forward - Upstream DNS servers"
    [ -n "$(echo "$corefile" | grep -E "^\s*cache")" ] && echo "  ✓ cache - DNS caching"
    [ -n "$(echo "$corefile" | grep -E "^\s*loop")" ] && echo "  ✓ loop - Loop detection"
    [ -n "$(echo "$corefile" | grep -E "^\s*reload")" ] && echo "  ✓ reload - Auto-reload config"
    [ -n "$(echo "$corefile" | grep -E "^\s*loadbalance")" ] && echo "  ✓ loadbalance - A/AAAA record balancing"
    [ -n "$(echo "$corefile" | grep -E "^\s*prometheus")" ] && echo "  ✓ prometheus - Metrics endpoint"
    [ -n "$(echo "$corefile" | grep -E "^\s*health")" ] && echo "  ✓ health - Health endpoint"
    [ -n "$(echo "$corefile" | grep -E "^\s*ready")" ] && echo "  ✓ ready - Readiness endpoint"
    
    # Check forward configuration
    forward_config=$(echo "$corefile" | grep -A1 "forward" | tail -1)
    if [ -n "$forward_config" ]; then
        echo ""
        echo "Upstream DNS servers: $forward_config"
    fi
else
    echo -e "${YELLOW}⚠ CoreDNS ConfigMap not found${NC}"
fi

echo ""
echo "5. DNS Resolution Tests..."
echo "------------------------"

# Get a running CoreDNS pod for tests
first_pod=$(echo "$coredns_pods" | jq -r '.items[] | select(.status.phase == "Running") | .metadata.name' | head -1)

if [ -n "$first_pod" ]; then
    # Test internal DNS resolution
    echo "Testing DNS resolution from CoreDNS pod..."
    
    # Test kubernetes.default
    echo -n "  kubernetes.default: "
    if kubectl exec -n "$NAMESPACE" "$first_pod" -- nslookup kubernetes.default 127.0.0.1 &> /dev/null; then
        echo -e "${GREEN}✓ Resolved${NC}"
    else
        echo -e "${RED}✗ Failed${NC}"
    fi
    
    # Test kube-dns service
    echo -n "  kube-dns.kube-system: "
    if kubectl exec -n "$NAMESPACE" "$first_pod" -- nslookup kube-dns.kube-system 127.0.0.1 &> /dev/null; then
        echo -e "${GREEN}✓ Resolved${NC}"
    else
        echo -e "${RED}✗ Failed${NC}"
    fi
    
    # Test external DNS
    echo -n "  External (google.com): "
    if kubectl exec -n "$NAMESPACE" "$first_pod" -- nslookup google.com 127.0.0.1 &> /dev/null; then
        echo -e "${GREEN}✓ Resolved${NC}"
    else
        echo -e "${YELLOW}⚠ Failed (check upstream DNS)${NC}"
    fi
fi

echo ""
echo "6. CoreDNS Metrics..."
echo "-------------------"

if [ -n "$first_pod" ]; then
    # Check if metrics endpoint is available
    echo -n "Metrics endpoint: "
    if kubectl exec -n "$NAMESPACE" "$first_pod" -- wget -qO- http://localhost:9153/metrics &> /dev/null; then
        echo -e "${GREEN}✓ Available${NC}"
        
        # Get some key metrics
        metrics=$(kubectl exec -n "$NAMESPACE" "$first_pod" -- wget -qO- http://localhost:9153/metrics 2>/dev/null || echo "")
        
        if [ -n "$metrics" ]; then
            # Extract key metrics
            total_queries=$(echo "$metrics" | grep "coredns_dns_requests_total" | awk '{sum+=$2} END {print sum}' || echo "0")
            cache_hits=$(echo "$metrics" | grep "coredns_cache_hits_total" | awk '{sum+=$2} END {print sum}' || echo "0")
            cache_misses=$(echo "$metrics" | grep "coredns_cache_misses_total" | awk '{sum+=$2} END {print sum}' || echo "0")
            
            echo ""
            echo "Query statistics:"
            echo "  Total DNS queries: ${total_queries:-0}"
            echo "  Cache hits: ${cache_hits:-0}"
            echo "  Cache misses: ${cache_misses:-0}"
            
            if [ "${total_queries:-0}" -gt 0 ] && [ "${cache_hits:-0}" -gt 0 ]; then
                cache_hit_rate=$(echo "scale=2; $cache_hits * 100 / ($cache_hits + $cache_misses)" | bc 2>/dev/null || echo "0")
                echo "  Cache hit rate: ${cache_hit_rate}%"
            fi
            
            # Check for errors
            servfail=$(echo "$metrics" | grep "coredns_dns_responses_total.*SERVFAIL" | awk '{sum+=$2} END {print sum}' || echo "0")
            if [ "${servfail:-0}" -gt 0 ]; then
                echo -e "  ${YELLOW}⚠ SERVFAIL responses: $servfail${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}⚠ Not accessible${NC}"
    fi
fi

echo ""
echo "7. CoreDNS Resource Usage..."
echo "-------------------------"

# Check resource requests and limits
echo "Resource configuration:"
echo "$coredns_pods" | jq -r '.items[0].spec.containers[0].resources | 
    "Requests:" +
    "\n  CPU: \(.requests.cpu // "not set")" +
    "\n  Memory: \(.requests.memory // "not set")" +
    "\nLimits:" +
    "\n  CPU: \(.limits.cpu // "not set")" +
    "\n  Memory: \(.limits.memory // "not set")"'

# Try to get actual usage if metrics-server is available
if kubectl top pods -n "$NAMESPACE" &> /dev/null; then
    echo ""
    echo "Current resource usage:"
    kubectl top pods -n "$NAMESPACE" -l "$COREDNS_LABEL"
fi

echo ""
echo "8. DNS Policy Compliance..."
echo "-------------------------"

# Check for common DNS issues
echo "Checking for common configuration issues..."

# Check if pods are using proper DNS policy
non_cluster_first=$(kubectl get pods --all-namespaces -o json | jq -r '.items[] | select(.spec.dnsPolicy != "ClusterFirst" and .spec.dnsPolicy != null) | "\(.metadata.namespace)/\(.metadata.name): \(.spec.dnsPolicy)"' | wc -l)

if [ "$non_cluster_first" -eq 0 ]; then
    echo -e "${GREEN}✓ All pods using appropriate DNS policies${NC}"
else
    echo -e "${YELLOW}⚠ Found $non_cluster_first pods with non-standard DNS policies${NC}"
fi

# Check for pods with custom DNS config
custom_dns=$(kubectl get pods --all-namespaces -o json | jq -r '.items[] | select(.spec.dnsConfig != null) | "\(.metadata.namespace)/\(.metadata.name)"' | wc -l)
if [ "$custom_dns" -gt 0 ]; then
    echo "  Pods with custom DNS config: $custom_dns"
fi

echo ""
echo "9. Recent CoreDNS Logs Analysis..."
echo "--------------------------------"

if [ -n "$first_pod" ]; then
    # Check for errors in logs
    echo "Analyzing recent logs..."
    
    error_count=$(kubectl logs -n "$NAMESPACE" "$first_pod" --tail=200 2>/dev/null | grep -ciE "error|fail|panic|timeout" || echo "0")
    
    if [ "$error_count" -gt 0 ]; then
        echo -e "${YELLOW}⚠ Found $error_count error messages in recent logs${NC}"
        echo "Recent errors:"
        kubectl logs -n "$NAMESPACE" "$first_pod" --tail=200 2>/dev/null | grep -iE "error|fail|panic|timeout" | tail -5
    else
        echo -e "${GREEN}✓ No errors found in recent logs${NC}"
    fi
    
    # Check for specific issues
    plugin_errors=$(kubectl logs -n "$NAMESPACE" "$first_pod" --tail=200 2>/dev/null | grep -c "plugin/errors" || echo "0")
    if [ "$plugin_errors" -gt 0 ]; then
        echo -e "${YELLOW}⚠ Plugin errors detected: $plugin_errors${NC}"
    fi
    
    forward_errors=$(kubectl logs -n "$NAMESPACE" "$first_pod" --tail=200 2>/dev/null | grep -c "forward.*i/o timeout" || echo "0")
    if [ "$forward_errors" -gt 0 ]; then
        echo -e "${YELLOW}⚠ Upstream DNS timeout errors: $forward_errors${NC}"
        echo "  Consider checking upstream DNS server connectivity"
    fi
fi

echo ""
echo "10. DNS Performance Test..."
echo "------------------------"

# Create a test pod for DNS performance testing
echo "Running DNS performance test..."

# Use a running pod in default namespace if available
test_pod=$(kubectl get pods -n default -o json | jq -r '.items[] | select(.status.phase == "Running") | .metadata.name' | head -1)

if [ -n "$test_pod" ]; then
    echo "Using pod $test_pod for DNS tests..."
    
    # Test DNS resolution time
    dns_test=$(kubectl exec -n default "$test_pod" -- sh -c 'time nslookup kubernetes.default 2>&1' 2>/dev/null || echo "failed")
    
    if [ "$dns_test" != "failed" ] && echo "$dns_test" | grep -q "Address"; then
        echo -e "${GREEN}✓ DNS resolution working${NC}"
        
        # Extract timing if possible
        real_time=$(echo "$dns_test" | grep "real" | awk '{print $2}')
        if [ -n "$real_time" ]; then
            echo "  Resolution time: $real_time"
        fi
    else
        echo -e "${YELLOW}⚠ DNS test failed or no suitable pod found${NC}"
    fi
else
    echo "No running pods in default namespace for testing"
fi

echo ""
echo "======================================"
echo "CoreDNS Health Check Complete"
echo ""
echo "Summary:"
echo "- CoreDNS pods: $running_count/$pod_count running"
echo "- DNS service endpoints: $endpoints"
[ -n "$total_queries" ] && echo "- Total queries processed: ${total_queries:-0}"
[ -n "$cache_hit_rate" ] && echo "- Cache hit rate: ${cache_hit_rate}%"
echo "======================================"
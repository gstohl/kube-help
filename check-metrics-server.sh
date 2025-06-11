#!/bin/bash

# Metrics Server Health Check Script
# This script checks the health status of metrics-server for resource monitoring

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

echo "======================================"
echo "Metrics Server Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

# Find metrics-server namespace
NAMESPACE=""
for ns in kube-system metrics-server monitoring; do
    if kubectl get deployment -n "$ns" metrics-server &> /dev/null; then
        NAMESPACE="$ns"
        break
    fi
done

if [ -z "$NAMESPACE" ]; then
    echo -e "${RED}Error: metrics-server not found in any namespace${NC}"
    echo "Checked namespaces: kube-system, metrics-server, monitoring"
    echo ""
    echo "To install metrics-server:"
    echo "kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
    exit 1
fi

echo -e "${BLUE}Found metrics-server in namespace: $NAMESPACE${NC}"
echo ""

echo "1. Metrics Server Deployment Status..."
echo "------------------------------------"

# Get deployment info
deployment=$(kubectl get deployment -n "$NAMESPACE" metrics-server -o json)
replicas=$(echo "$deployment" | jq '.spec.replicas')
ready_replicas=$(echo "$deployment" | jq '.status.readyReplicas // 0')
available_replicas=$(echo "$deployment" | jq '.status.availableReplicas // 0')

echo "Metrics Server Deployment:"
if [ "$ready_replicas" -eq "$replicas" ]; then
    echo -e "${GREEN}✓ All replicas ready: $ready_replicas/$replicas${NC}"
else
    echo -e "${YELLOW}⚠ Only $ready_replicas/$replicas replicas ready${NC}"
fi
echo "  Available replicas: $available_replicas"

# Check deployment conditions
conditions=$(echo "$deployment" | jq -r '.status.conditions[]? | "\(.type): \(.status) (\(.reason // ""))"')
if [ -n "$conditions" ]; then
    echo "  Conditions:"
    echo "$conditions" | sed 's/^/    /'
fi

echo ""
echo "2. Metrics Server Pod Health..."
echo "-----------------------------"

# Get metrics-server pods
metrics_pods=$(kubectl get pods -n "$NAMESPACE" -l k8s-app=metrics-server -o json)
pod_count=$(echo "$metrics_pods" | jq '.items | length')
running_count=$(echo "$metrics_pods" | jq '[.items[] | select(.status.phase == "Running")] | length')

echo "Total metrics-server pods: $pod_count"
if [ "$running_count" -eq "$pod_count" ]; then
    echo -e "${GREEN}✓ All pods running: $running_count/$pod_count${NC}"
else
    echo -e "${YELLOW}⚠ Only $running_count/$pod_count pods running${NC}"
fi

# Show pod details
echo ""
echo "Pod details:"
echo "$metrics_pods" | jq -r '.items[] | 
    "\(.metadata.name):" +
    "\n  Node: \(.spec.nodeName)" +
    "\n  Status: \(.status.phase)" +
    "\n  Ready: \(if .status.conditions[] | select(.type == "Ready") | .status == "True" then "Yes" else "No" end)" +
    "\n  Restarts: \(.status.containerStatuses[0].restartCount // 0)"'

# Check for high restart counts
high_restart_pods=$(echo "$metrics_pods" | jq -r '.items[] | select(.status.containerStatuses[0].restartCount > 5) | "\(.metadata.name): \(.status.containerStatuses[0].restartCount) restarts"')
if [ -n "$high_restart_pods" ]; then
    echo ""
    echo -e "${YELLOW}⚠ Pods with high restart counts:${NC}"
    echo "$high_restart_pods"
fi

echo ""
echo "3. Metrics Server Service..."
echo "-------------------------"

# Check metrics-server service
service=$(kubectl get service -n "$NAMESPACE" metrics-server -o json 2>/dev/null)
if [ -n "$service" ] && [ "$service" != "null" ]; then
    echo -e "${GREEN}✓ Metrics Server service found${NC}"
    echo "  ClusterIP: $(echo "$service" | jq -r '.spec.clusterIP')"
    echo "  Port: $(echo "$service" | jq -r '.spec.ports[0].port')/$(echo "$service" | jq -r '.spec.ports[0].protocol')"
    
    # Check endpoints
    endpoints=$(kubectl get endpoints -n "$NAMESPACE" metrics-server -o json | jq '.subsets[0].addresses | length' 2>/dev/null || echo "0")
    echo "  Active endpoints: $endpoints"
else
    echo -e "${RED}✗ Metrics Server service not found${NC}"
fi

echo ""
echo "4. API Service Registration..."
echo "----------------------------"

# Check APIService registration
apiservice=$(kubectl get apiservice v1beta1.metrics.k8s.io -o json 2>/dev/null)
if [ -n "$apiservice" ] && [ "$apiservice" != "null" ]; then
    available=$(echo "$apiservice" | jq -r '.status.conditions[] | select(.type == "Available") | .status')
    
    if [ "$available" = "True" ]; then
        echo -e "${GREEN}✓ Metrics API service is available${NC}"
    else
        echo -e "${RED}✗ Metrics API service is not available${NC}"
        echo "Conditions:"
        echo "$apiservice" | jq -r '.status.conditions[] | "  \(.type): \(.status) - \(.reason): \(.message)"'
    fi
else
    echo -e "${RED}✗ Metrics API service not registered${NC}"
fi

echo ""
echo "5. Metrics Server Configuration..."
echo "--------------------------------"

# Get first running pod for checks
first_pod=$(echo "$metrics_pods" | jq -r '.items[] | select(.status.phase == "Running") | .metadata.name' | head -1)

if [ -n "$first_pod" ]; then
    # Check container args
    args=$(echo "$metrics_pods" | jq -r '.items[0].spec.containers[0].args[]' 2>/dev/null)
    
    echo "Configuration parameters:"
    echo "$args" | grep -E "kubelet-insecure-tls|kubelet-preferred-address-types|metric-resolution" | sed 's/^/  /'
    
    # Check for insecure TLS (common in dev environments)
    if echo "$args" | grep -q "kubelet-insecure-tls"; then
        echo -e "  ${YELLOW}⚠ Running with --kubelet-insecure-tls (development mode)${NC}"
    fi
fi

echo ""
echo "6. Testing Metrics Availability..."
echo "--------------------------------"

# Test kubectl top nodes
echo -n "kubectl top nodes: "
if kubectl top nodes &> /dev/null; then
    echo -e "${GREEN}✓ Working${NC}"
    echo ""
    echo "Sample node metrics:"
    kubectl top nodes | head -5
else
    echo -e "${RED}✗ Not working${NC}"
    echo "  Error: Cannot fetch node metrics"
fi

echo ""
# Test kubectl top pods
echo -n "kubectl top pods: "
if kubectl top pods -n kube-system &> /dev/null; then
    echo -e "${GREEN}✓ Working${NC}"
    echo ""
    echo "Sample pod metrics (kube-system):"
    kubectl top pods -n kube-system | head -5
else
    echo -e "${RED}✗ Not working${NC}"
    echo "  Error: Cannot fetch pod metrics"
fi

echo ""
echo "7. Metrics Server Resource Usage..."
echo "---------------------------------"

# Check resource requests and limits
echo "Resource configuration:"
echo "$metrics_pods" | jq -r '.items[0].spec.containers[0].resources | 
    "Requests:" +
    "\n  CPU: \(.requests.cpu // "not set")" +
    "\n  Memory: \(.requests.memory // "not set")" +
    "\nLimits:" +
    "\n  CPU: \(.limits.cpu // "not set")" +
    "\n  Memory: \(.limits.memory // "not set")"'

# Try to get actual usage
if [ "$running_count" -gt 0 ] && kubectl top pods -n "$NAMESPACE" &> /dev/null; then
    echo ""
    echo "Current resource usage:"
    kubectl top pods -n "$NAMESPACE" -l k8s-app=metrics-server
fi

echo ""
echo "8. Checking Metrics Server Endpoints..."
echo "-------------------------------------"

if [ -n "$first_pod" ]; then
    # Check metrics endpoint
    echo -n "Metrics endpoint (/metrics): "
    if kubectl exec -n "$NAMESPACE" "$first_pod" -- wget -qO- https://localhost:4443/metrics --no-check-certificate &> /dev/null; then
        echo -e "${GREEN}✓ Accessible${NC}"
        
        # Get some key metrics
        metrics=$(kubectl exec -n "$NAMESPACE" "$first_pod" -- wget -qO- https://localhost:4443/metrics --no-check-certificate 2>/dev/null | head -50)
        
        # Check scrape duration
        scrape_duration=$(echo "$metrics" | grep "metrics_server_scraper_duration_seconds{quantile" | grep "0.99" | awk '{print $2}' | head -1)
        if [ -n "$scrape_duration" ]; then
            echo "  Scrape duration (p99): ${scrape_duration}s"
        fi
    else
        echo -e "${YELLOW}⚠ Not accessible${NC}"
    fi
    
    # Check readiness endpoint
    echo -n "Readiness endpoint (/readyz): "
    if kubectl exec -n "$NAMESPACE" "$first_pod" -- wget -qO- https://localhost:4443/readyz --no-check-certificate &> /dev/null; then
        echo -e "${GREEN}✓ Ready${NC}"
    else
        echo -e "${RED}✗ Not ready${NC}"
    fi
fi

echo ""
echo "9. Checking Kubelet Connectivity..."
echo "---------------------------------"

# Check recent logs for kubelet connection issues
if [ -n "$first_pod" ]; then
    echo "Analyzing logs for kubelet connection issues..."
    
    # Common error patterns
    timeout_errors=$(kubectl logs -n "$NAMESPACE" "$first_pod" --tail=100 2>/dev/null | grep -c "unable to fetch metrics from node" || echo "0")
    tls_errors=$(kubectl logs -n "$NAMESPACE" "$first_pod" --tail=100 2>/dev/null | grep -c "x509" || echo "0")
    scrape_errors=$(kubectl logs -n "$NAMESPACE" "$first_pod" --tail=100 2>/dev/null | grep -c "failed to scrape" || echo "0")
    
    if [ "$timeout_errors" -eq 0 ] && [ "$tls_errors" -eq 0 ] && [ "$scrape_errors" -eq 0 ]; then
        echo -e "${GREEN}✓ No kubelet connectivity issues detected${NC}"
    else
        echo -e "${YELLOW}⚠ Kubelet connectivity issues detected:${NC}"
        [ "$timeout_errors" -gt 0 ] && echo "  - Timeout errors: $timeout_errors"
        [ "$tls_errors" -gt 0 ] && echo "  - TLS/Certificate errors: $tls_errors"
        [ "$scrape_errors" -gt 0 ] && echo "  - Scrape failures: $scrape_errors"
        
        echo ""
        echo "Recent error samples:"
        kubectl logs -n "$NAMESPACE" "$first_pod" --tail=100 2>/dev/null | grep -E "unable to fetch|x509|failed to scrape" | tail -3
    fi
fi

echo ""
echo "10. HPA (Horizontal Pod Autoscaler) Status..."
echo "-------------------------------------------"

# Check if any HPAs are using metrics
hpa_count=$(kubectl get hpa --all-namespaces -o json | jq '.items | length')

if [ "$hpa_count" -gt 0 ]; then
    echo "Found $hpa_count Horizontal Pod Autoscaler(s)"
    
    # Check HPA status
    hpa_with_metrics=$(kubectl get hpa --all-namespaces -o json | jq '[.items[] | select(.status.currentMetrics != null)] | length')
    hpa_unknown=$(kubectl get hpa --all-namespaces -o json | jq '[.items[] | select(.status.currentMetrics == null or .status.conditions[]?.reason == "FailedGetResourceMetric")] | length')
    
    if [ "$hpa_unknown" -eq 0 ]; then
        echo -e "${GREEN}✓ All HPAs receiving metrics: $hpa_with_metrics/$hpa_count${NC}"
    else
        echo -e "${YELLOW}⚠ HPAs not receiving metrics: $hpa_unknown/$hpa_count${NC}"
        echo "Problematic HPAs:"
        kubectl get hpa --all-namespaces | grep -E "unknown|<unknown>" | head -5
    fi
else
    echo "No Horizontal Pod Autoscalers found"
fi

echo ""
echo "11. Recent Metrics Server Events..."
echo "---------------------------------"

# Check for recent events
events=$(kubectl get events -n "$NAMESPACE" --field-selector involvedObject.name=metrics-server -o json | jq -r '.items | sort_by(.lastTimestamp) | reverse | .[0:5] | .[] | "\(.lastTimestamp): \(.reason) - \(.message)"')

if [ -n "$events" ]; then
    echo "Recent events:"
    echo "$events"
else
    echo -e "${GREEN}✓ No recent events${NC}"
fi

echo ""
echo "======================================"
echo "Metrics Server Health Check Complete"
echo ""
echo "Summary:"
echo "- Deployment: $ready_replicas/$replicas replicas ready"
echo "- API Service: $([ "$available" = "True" ] && echo "Available" || echo "Not Available")"
echo "- Node metrics: $(kubectl top nodes &> /dev/null && echo "Working" || echo "Not Working")"
echo "- Pod metrics: $(kubectl top pods -n kube-system &> /dev/null && echo "Working" || echo "Not Working")"
[ "$hpa_count" -gt 0 ] && echo "- HPAs with metrics: $hpa_with_metrics/$hpa_count"
echo "======================================"
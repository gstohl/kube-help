#!/bin/bash

# Loki Logging System Health Check Script
# This script checks the health status of Loki and its components in Kubernetes

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

echo "======================================"
echo "Loki Logging System Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

# Find Loki namespace
NAMESPACE=""
for ns in loki loki-stack logging monitoring observability; do
    if kubectl get namespace "$ns" &> /dev/null; then
        if kubectl get pods -n "$ns" -l "app=loki" &> /dev/null || \
           kubectl get pods -n "$ns" -l "app.kubernetes.io/name=loki" &> /dev/null || \
           kubectl get pods -n "$ns" -l "name=loki" &> /dev/null; then
            NAMESPACE="$ns"
            break
        fi
    fi
done

if [ -z "$NAMESPACE" ]; then
    echo -e "${RED}Error: Loki not found in any namespace.${NC}"
    echo "Checked namespaces: loki, loki-stack, logging, monitoring, observability"
    exit 1
fi

echo -e "${BLUE}Found Loki in namespace: $NAMESPACE${NC}"
echo ""

echo "1. Checking Loki Components..."
echo "-----------------------------"

# Check Loki main component
echo "Loki Server:"
loki_pods=$(kubectl get pods -n "$NAMESPACE" -l "app=loki" -o json 2>/dev/null || \
            kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=loki" -o json 2>/dev/null || \
            kubectl get pods -n "$NAMESPACE" -l "name=loki" -o json 2>/dev/null)

loki_count=$(echo "$loki_pods" | jq '.items | length')
if [ "$loki_count" -eq 0 ]; then
    echo -e "${RED}✗ No Loki server pods found${NC}"
else
    loki_ready=$(echo "$loki_pods" | jq '[.items[] | select(.status.phase == "Running" and all(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length')
    
    if [ "$loki_ready" -eq "$loki_count" ]; then
        echo -e "${GREEN}✓ Loki server: $loki_ready/$loki_count pods ready${NC}"
    else
        echo -e "${YELLOW}⚠ Loki server: $loki_ready/$loki_count pods ready${NC}"
        kubectl get pods -n "$NAMESPACE" -l "app=loki" 2>/dev/null || \
        kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=loki" 2>/dev/null
    fi
    
    # Check Loki targets/mode
    first_loki_pod=$(echo "$loki_pods" | jq -r '.items[0].metadata.name')
    if [ -n "$first_loki_pod" ]; then
        echo ""
        echo "Loki Mode:"
        mode=$(kubectl get pod -n "$NAMESPACE" "$first_loki_pod" -o json | jq -r '.spec.containers[0].args[]' | grep -E "target|mode" || echo "single-binary")
        echo "  Operating in: $mode mode"
    fi
fi

# Check Promtail
echo ""
echo "Promtail (Log Collector):"
promtail_ds=$(kubectl get daemonset -n "$NAMESPACE" -l "app=promtail" -o json 2>/dev/null || \
              kubectl get daemonset -n "$NAMESPACE" -l "app.kubernetes.io/name=promtail" -o json 2>/dev/null)

if [ "$(echo "$promtail_ds" | jq '.items | length')" -gt 0 ]; then
    desired=$(echo "$promtail_ds" | jq '.items[0].status.desiredNumberScheduled')
    ready=$(echo "$promtail_ds" | jq '.items[0].status.numberReady // 0')
    
    if [ "$ready" -eq "$desired" ]; then
        echo -e "${GREEN}✓ Promtail DaemonSet: $ready/$desired pods ready${NC}"
    else
        echo -e "${YELLOW}⚠ Promtail DaemonSet: $ready/$desired pods ready${NC}"
        echo "Nodes without Promtail:"
        kubectl get pods -n "$NAMESPACE" -l "app=promtail" -o wide | grep -v Running || true
    fi
else
    echo -e "${YELLOW}⚠ Promtail DaemonSet not found${NC}"
fi

# Check Gateway (if deployed)
echo ""
echo "Loki Gateway:"
gateway_pods=$(kubectl get pods -n "$NAMESPACE" -l "app=loki-gateway" -o json 2>/dev/null || \
               kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/component=gateway" -o json 2>/dev/null)

if [ "$(echo "$gateway_pods" | jq '.items | length')" -gt 0 ]; then
    gateway_ready=$(echo "$gateway_pods" | jq '[.items[] | select(.status.phase == "Running")] | length')
    gateway_total=$(echo "$gateway_pods" | jq '.items | length')
    
    if [ "$gateway_ready" -eq "$gateway_total" ]; then
        echo -e "${GREEN}✓ Gateway: $gateway_ready/$gateway_total pods ready${NC}"
    else
        echo -e "${YELLOW}⚠ Gateway: $gateway_ready/$gateway_total pods ready${NC}"
    fi
else
    echo "  No gateway component found (single-binary mode likely)"
fi

echo ""
echo "2. Checking Loki Services..."
echo "---------------------------"

services=$(kubectl get services -n "$NAMESPACE" -o json | jq -r '.items[] | select(.metadata.name | contains("loki")) | .metadata.name')
if [ -n "$services" ]; then
    echo "Loki services found:"
    for svc in $services; do
        endpoints=$(kubectl get endpoints -n "$NAMESPACE" "$svc" -o json | jq '.subsets[0].addresses | length // 0')
        ports=$(kubectl get service -n "$NAMESPACE" "$svc" -o json | jq -r '.spec.ports[] | "\(.port)/\(.protocol)"' | tr '\n' ', ' | sed 's/,$//')
        echo "  - $svc: $endpoints endpoint(s), ports: $ports"
    done
else
    echo -e "${YELLOW}⚠ No Loki services found${NC}"
fi

echo ""
echo "3. Checking Loki Storage..."
echo "--------------------------"

# Check PVCs
pvcs=$(kubectl get pvc -n "$NAMESPACE" -o json | jq -r '.items[] | select(.metadata.name | contains("loki"))')
if [ -n "$pvcs" ]; then
    echo "Persistent Volume Claims:"
    kubectl get pvc -n "$NAMESPACE" | grep loki
else
    echo "No PVCs found (might be using object storage or emptyDir)"
fi

# Check for object storage config
if [ "$loki_count" -gt 0 ]; then
    echo ""
    echo "Storage Configuration:"
    first_loki_pod=$(echo "$loki_pods" | jq -r '.items[0].metadata.name')
    
    # Check for S3/GCS/Azure config in env vars
    storage_env=$(kubectl get pod -n "$NAMESPACE" "$first_loki_pod" -o json | jq -r '.spec.containers[0].env[]? | select(.name | contains("S3") or contains("GCS") or contains("AZURE")) | .name' | head -5)
    if [ -n "$storage_env" ]; then
        echo "  Object storage environment variables found:"
        echo "$storage_env" | sed 's/^/    - /'
    fi
    
    # Check ConfigMap for storage config
    config_maps=$(kubectl get configmap -n "$NAMESPACE" -o json | jq -r '.items[] | select(.metadata.name | contains("loki")) | .metadata.name')
    if [ -n "$config_maps" ]; then
        echo "  Configuration found in: $config_maps"
    fi
fi

echo ""
echo "4. Checking Loki Distributor Ring (if applicable)..."
echo "---------------------------------------------------"

if [ "$loki_count" -gt 0 ] && [ -n "$first_loki_pod" ]; then
    # Try to get ring status
    ring_status=$(kubectl exec -n "$NAMESPACE" "$first_loki_pod" -- wget -qO- http://localhost:3100/ring 2>/dev/null || echo "")
    
    if [ -n "$ring_status" ]; then
        echo -e "${GREEN}✓ Ring endpoint accessible${NC}"
        # You could parse the ring status here if needed
    else
        echo "Ring status not available (single-binary mode or different port)"
    fi
fi

echo ""
echo "5. Checking Loki API Health..."
echo "-----------------------------"

# Find Loki service
loki_service=$(kubectl get service -n "$NAMESPACE" -o json | jq -r '.items[] | select(.metadata.name | contains("loki") and (.metadata.name | contains("headless") | not)) | .metadata.name' | head -1)

if [ -n "$loki_service" ]; then
    # Check ready endpoint
    echo -n "Loki API ready check: "
    if kubectl exec -n "$NAMESPACE" "$first_loki_pod" -- wget -qO- http://localhost:3100/ready &> /dev/null; then
        echo -e "${GREEN}✓ Ready${NC}"
    else
        echo -e "${RED}✗ Not ready${NC}"
    fi
    
    # Check metrics
    echo -n "Loki metrics endpoint: "
    if kubectl exec -n "$NAMESPACE" "$first_loki_pod" -- wget -qO- http://localhost:3100/metrics &> /dev/null; then
        echo -e "${GREEN}✓ Accessible${NC}"
    else
        echo -e "${YELLOW}⚠ Not accessible${NC}"
    fi
fi

echo ""
echo "6. Checking Log Ingestion Rate..."
echo "--------------------------------"

if [ -n "$first_loki_pod" ]; then
    # Get some metrics if available
    metrics=$(kubectl exec -n "$NAMESPACE" "$first_loki_pod" -- wget -qO- http://localhost:3100/metrics 2>/dev/null || echo "")
    
    if [ -n "$metrics" ]; then
        # Extract some key metrics
        ingestion_rate=$(echo "$metrics" | grep "loki_distributor_lines_received_total" | tail -1 | awk '{print $2}' || echo "0")
        if [ -n "$ingestion_rate" ] && [ "$ingestion_rate" != "0" ]; then
            echo -e "${GREEN}✓ Logs are being ingested${NC}"
            echo "  Total lines received: $ingestion_rate"
        fi
        
        # Check for errors
        ingestion_errors=$(echo "$metrics" | grep "loki_distributor_ingester_append_failures_total" | tail -1 | awk '{print $2}' || echo "0")
        if [ -n "$ingestion_errors" ] && [ "$ingestion_errors" != "0" ]; then
            echo -e "${YELLOW}⚠ Ingestion errors detected: $ingestion_errors${NC}"
        fi
    else
        echo "Metrics not available for ingestion rate check"
    fi
fi

echo ""
echo "7. Checking Promtail Targets..."
echo "------------------------------"

# Get a promtail pod to check
promtail_pod=$(kubectl get pods -n "$NAMESPACE" -l "app=promtail" -o json 2>/dev/null | jq -r '.items[0].metadata.name' || \
               kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=promtail" -o json 2>/dev/null | jq -r '.items[0].metadata.name')

if [ -n "$promtail_pod" ] && [ "$promtail_pod" != "null" ]; then
    echo -n "Promtail targets check: "
    if kubectl exec -n "$NAMESPACE" "$promtail_pod" -- wget -qO- http://localhost:3101/targets 2>/dev/null | grep -q "job"; then
        echo -e "${GREEN}✓ Targets configured${NC}"
    else
        echo -e "${YELLOW}⚠ No targets found or endpoint not accessible${NC}"
    fi
    
    # Check Promtail config
    echo -n "Promtail configuration: "
    if kubectl exec -n "$NAMESPACE" "$promtail_pod" -- cat /etc/promtail/config.yml &> /dev/null || \
       kubectl exec -n "$NAMESPACE" "$promtail_pod" -- cat /etc/promtail/promtail.yaml &> /dev/null; then
        echo -e "${GREEN}✓ Configuration file found${NC}"
    else
        echo -e "${YELLOW}⚠ Configuration file not found at expected location${NC}"
    fi
fi

echo ""
echo "8. Recent Events and Errors..."
echo "-----------------------------"

# Check for recent warning events
events=$(kubectl get events -n "$NAMESPACE" --field-selector type=Warning -o json | jq -r '.items | sort_by(.lastTimestamp) | reverse | .[0:5] | .[] | "\(.lastTimestamp): \(.reason) - \(.message)"')

if [ -n "$events" ]; then
    echo -e "${YELLOW}Recent warning events:${NC}"
    echo "$events"
else
    echo -e "${GREEN}✓ No recent warning events${NC}"
fi

# Check pod logs for errors
echo ""
echo "Recent errors in Loki logs:"
if [ -n "$first_loki_pod" ]; then
    errors=$(kubectl logs -n "$NAMESPACE" "$first_loki_pod" --tail=100 2>/dev/null | grep -i "error\|fail\|panic" | tail -5)
    if [ -n "$errors" ]; then
        echo -e "${YELLOW}Recent errors found:${NC}"
        echo "$errors"
    else
        echo -e "${GREEN}✓ No recent errors in logs${NC}"
    fi
fi

echo ""
echo "9. Integration Status..."
echo "-----------------------"

# Check for Grafana datasource
grafana_ns=$(kubectl get pods --all-namespaces -l "app.kubernetes.io/name=grafana" -o json 2>/dev/null | jq -r '.items[0].metadata.namespace' || echo "")
if [ -n "$grafana_ns" ] && [ "$grafana_ns" != "null" ]; then
    echo -e "${GREEN}✓ Grafana found in namespace: $grafana_ns${NC}"
    echo "  Loki can be configured as a datasource in Grafana"
else
    echo "Grafana not found (optional for visualization)"
fi

echo ""
echo "======================================"
echo "Loki Health Check Complete"
echo ""
echo "Summary:"
echo "- Namespace: $NAMESPACE"
echo "- Loki pods: $loki_ready/$loki_count ready"
[ -n "$promtail_ds" ] && echo "- Promtail: $ready/$desired nodes covered"
echo "======================================"
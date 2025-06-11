#!/bin/bash

# etcd Health Check Script
# This script checks the health status of etcd - Kubernetes' key-value store

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

echo "======================================"
echo "etcd Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

# Detect cluster type and etcd location
ETCD_NAMESPACE="kube-system"
ETCD_PODS=""
EXTERNAL_ETCD=false

echo "1. Detecting etcd Configuration..."
echo "--------------------------------"

# Check for etcd pods in kube-system
etcd_pods=$(kubectl get pods -n "$ETCD_NAMESPACE" -l component=etcd -o json 2>/dev/null)
etcd_count=$(echo "$etcd_pods" | jq '.items | length')

if [ "$etcd_count" -gt 0 ]; then
    echo -e "${GREEN}✓ Found $etcd_count etcd pod(s) in $ETCD_NAMESPACE${NC}"
    ETCD_PODS="$etcd_pods"
else
    # Check for static pod manifests (typical for kubeadm clusters)
    echo "Checking for etcd static pods..."
    static_etcd=$(kubectl get pods -n "$ETCD_NAMESPACE" -o json | jq '.items[] | select(.metadata.name | startswith("etcd-"))')
    
    if [ -n "$static_etcd" ]; then
        ETCD_PODS=$(kubectl get pods -n "$ETCD_NAMESPACE" -o json | jq '.items[] | select(.metadata.name | startswith("etcd-"))' | jq -s '{"items": .}')
        etcd_count=$(echo "$ETCD_PODS" | jq '.items | length')
        echo -e "${GREEN}✓ Found $etcd_count etcd static pod(s)${NC}"
    else
        echo -e "${YELLOW}⚠ No etcd pods found. Checking for external etcd...${NC}"
        EXTERNAL_ETCD=true
    fi
fi

echo ""
echo "2. etcd Pod Health Status..."
echo "--------------------------"

if [ "$EXTERNAL_ETCD" = false ] && [ "$etcd_count" -gt 0 ]; then
    # Check pod status
    running_count=$(echo "$ETCD_PODS" | jq '[.items[] | select(.status.phase == "Running")] | length')
    
    if [ "$running_count" -eq "$etcd_count" ]; then
        echo -e "${GREEN}✓ All etcd pods are running: $running_count/$etcd_count${NC}"
    else
        echo -e "${YELLOW}⚠ Only $running_count/$etcd_count etcd pods are running${NC}"
    fi
    
    # Show pod details
    echo ""
    echo "etcd pod details:"
    echo "$ETCD_PODS" | jq -r '.items[] | "\(.metadata.name) - Node: \(.spec.nodeName) - Status: \(.status.phase)"'
    
    # Check for restarts
    high_restart_pods=$(echo "$ETCD_PODS" | jq -r '.items[] | select(.status.containerStatuses[0].restartCount > 5) | "\(.metadata.name): \(.status.containerStatuses[0].restartCount) restarts"')
    if [ -n "$high_restart_pods" ]; then
        echo -e "${YELLOW}⚠ Pods with high restart counts:${NC}"
        echo "$high_restart_pods"
    fi
else
    echo "Skipping pod health checks (external etcd or no pods found)"
fi

echo ""
echo "3. etcd Cluster Health..."
echo "-----------------------"

# Try to get etcdctl access
ETCDCTL_AVAILABLE=false
ETCD_ENDPOINTS=""
ETCD_CACERT=""
ETCD_CERT=""
ETCD_KEY=""

if [ "$EXTERNAL_ETCD" = false ] && [ "$etcd_count" -gt 0 ]; then
    # Get first etcd pod
    first_etcd_pod=$(echo "$ETCD_PODS" | jq -r '.items[0].metadata.name')
    
    # Check if we can use etcdctl
    if kubectl exec -n "$ETCD_NAMESPACE" "$first_etcd_pod" -- which etcdctl &> /dev/null; then
        ETCDCTL_AVAILABLE=true
        
        # Get etcd endpoints from pod
        ETCD_ENDPOINTS=$(kubectl exec -n "$ETCD_NAMESPACE" "$first_etcd_pod" -- printenv ETCDCTL_ENDPOINTS 2>/dev/null || echo "https://127.0.0.1:2379")
        
        # Try to get certificates paths
        ETCD_CACERT="/etc/kubernetes/pki/etcd/ca.crt"
        ETCD_CERT="/etc/kubernetes/pki/etcd/server.crt"
        ETCD_KEY="/etc/kubernetes/pki/etcd/server.key"
        
        echo "Using etcdctl for health checks..."
        
        # Check cluster health
        echo -n "Cluster health: "
        health_output=$(kubectl exec -n "$ETCD_NAMESPACE" "$first_etcd_pod" -- etcdctl \
            --endpoints="$ETCD_ENDPOINTS" \
            --cacert="$ETCD_CACERT" \
            --cert="$ETCD_CERT" \
            --key="$ETCD_KEY" \
            endpoint health 2>&1 || echo "failed")
        
        if echo "$health_output" | grep -q "is healthy"; then
            echo -e "${GREEN}✓ Healthy${NC}"
            echo "$health_output" | grep "is healthy"
        else
            echo -e "${RED}✗ Unhealthy${NC}"
            echo "$health_output"
        fi
    else
        echo -e "${YELLOW}⚠ etcdctl not available in pod, using alternative checks${NC}"
    fi
fi

# Alternative health check via API
if [ "$ETCDCTL_AVAILABLE" = false ] && [ "$etcd_count" -gt 0 ]; then
    echo ""
    echo "Checking etcd health via API endpoints..."
    
    first_etcd_pod=$(echo "$ETCD_PODS" | jq -r '.items[0].metadata.name')
    
    # Check /health endpoint
    echo -n "Health endpoint check: "
    if kubectl exec -n "$ETCD_NAMESPACE" "$first_etcd_pod" -- wget -qO- http://127.0.0.1:2381/health 2>/dev/null | grep -q "true"; then
        echo -e "${GREEN}✓ Healthy${NC}"
    else
        echo -e "${YELLOW}⚠ Could not verify health via HTTP endpoint${NC}"
    fi
fi

echo ""
echo "4. etcd Member Status..."
echo "----------------------"

if [ "$ETCDCTL_AVAILABLE" = true ]; then
    # List members
    echo "Cluster members:"
    member_list=$(kubectl exec -n "$ETCD_NAMESPACE" "$first_etcd_pod" -- etcdctl \
        --endpoints="$ETCD_ENDPOINTS" \
        --cacert="$ETCD_CACERT" \
        --cert="$ETCD_CERT" \
        --key="$ETCD_KEY" \
        member list -w table 2>&1 || echo "failed")
    
    if [ "$member_list" != "failed" ]; then
        echo "$member_list"
        
        # Count healthy members
        healthy_members=$(echo "$member_list" | grep -c "started" || echo "0")
        echo ""
        echo "Healthy members: $healthy_members"
    else
        echo -e "${YELLOW}⚠ Could not retrieve member list${NC}"
    fi
fi

echo ""
echo "5. etcd Performance Metrics..."
echo "----------------------------"

if [ "$ETCDCTL_AVAILABLE" = true ]; then
    # Check endpoint status for performance metrics
    echo "Endpoint status:"
    status_output=$(kubectl exec -n "$ETCD_NAMESPACE" "$first_etcd_pod" -- etcdctl \
        --endpoints="$ETCD_ENDPOINTS" \
        --cacert="$ETCD_CACERT" \
        --cert="$ETCD_CERT" \
        --key="$ETCD_KEY" \
        endpoint status -w table 2>&1 || echo "failed")
    
    if [ "$status_output" != "failed" ]; then
        echo "$status_output"
    else
        echo -e "${YELLOW}⚠ Could not retrieve endpoint status${NC}"
    fi
fi

echo ""
echo "6. etcd Database Size..."
echo "----------------------"

if [ "$etcd_count" -gt 0 ]; then
    # Check database size
    for i in $(seq 0 $((etcd_count - 1))); do
        pod_name=$(echo "$ETCD_PODS" | jq -r ".items[$i].metadata.name")
        
        # Try to get DB size
        db_size=$(kubectl exec -n "$ETCD_NAMESPACE" "$pod_name" -- sh -c 'du -sh /var/lib/etcd/member/snap/db 2>/dev/null | cut -f1' || echo "unknown")
        
        echo "$pod_name database size: $db_size"
    done
    
    # Check for database size warnings in logs
    echo ""
    echo "Checking for database size warnings..."
    size_warnings=$(kubectl logs -n "$ETCD_NAMESPACE" "$first_etcd_pod" --tail=100 2>/dev/null | grep -i "database space exceeded" | wc -l || echo "0")
    
    if [ "$size_warnings" -gt 0 ]; then
        echo -e "${YELLOW}⚠ Found $size_warnings database size warnings in recent logs${NC}"
        echo "Consider compacting and defragmenting the database"
    else
        echo -e "${GREEN}✓ No database size warnings found${NC}"
    fi
fi

echo ""
echo "7. etcd Alarm Status..."
echo "---------------------"

if [ "$ETCDCTL_AVAILABLE" = true ]; then
    # Check for alarms
    echo "Checking for active alarms..."
    alarms=$(kubectl exec -n "$ETCD_NAMESPACE" "$first_etcd_pod" -- etcdctl \
        --endpoints="$ETCD_ENDPOINTS" \
        --cacert="$ETCD_CACERT" \
        --cert="$ETCD_CERT" \
        --key="$ETCD_KEY" \
        alarm list 2>&1 || echo "failed")
    
    if [ "$alarms" = "failed" ]; then
        echo -e "${YELLOW}⚠ Could not check alarm status${NC}"
    elif [ -z "$alarms" ] || [ "$alarms" = "" ]; then
        echo -e "${GREEN}✓ No active alarms${NC}"
    else
        echo -e "${RED}✗ Active alarms found:${NC}"
        echo "$alarms"
    fi
fi

echo ""
echo "8. etcd Backup Status..."
echo "----------------------"

# Check for backup CronJobs or Jobs
backup_cronjobs=$(kubectl get cronjobs --all-namespaces -o json | jq '.items[] | select(.metadata.name | contains("etcd") and contains("backup"))' | jq -s 'length')
backup_jobs=$(kubectl get jobs --all-namespaces -o json | jq '.items[] | select(.metadata.name | contains("etcd") and contains("backup"))' | jq -s 'length')

if [ "$backup_cronjobs" -gt 0 ] || [ "$backup_jobs" -gt 0 ]; then
    echo -e "${GREEN}✓ etcd backup jobs found${NC}"
    [ "$backup_cronjobs" -gt 0 ] && echo "  - Backup CronJobs: $backup_cronjobs"
    [ "$backup_jobs" -gt 0 ] && echo "  - Recent backup Jobs: $backup_jobs"
    
    # Show last backup job
    last_backup=$(kubectl get jobs --all-namespaces -o json | jq -r '.items[] | select(.metadata.name | contains("etcd") and contains("backup")) | "\(.metadata.namespace)/\(.metadata.name): \(.status.succeeded // 0)/\(.status.failed // 0) (succeeded/failed)"' | tail -1)
    [ -n "$last_backup" ] && echo "  - Last backup job: $last_backup"
else
    echo -e "${YELLOW}⚠ No etcd backup jobs found${NC}"
    echo "  Consider setting up regular etcd backups"
fi

echo ""
echo "9. etcd Resource Usage..."
echo "-----------------------"

if [ "$etcd_count" -gt 0 ]; then
    # Check resource usage
    echo "Resource requests and limits:"
    echo "$ETCD_PODS" | jq -r '.items[] | 
        .metadata.name as $name |
        .spec.containers[0].resources |
        "\($name):" +
        "\n  Requests: CPU: \(.requests.cpu // "none"), Memory: \(.requests.memory // "none")" +
        "\n  Limits: CPU: \(.limits.cpu // "none"), Memory: \(.limits.memory // "none")"'
    
    # Try to get actual usage if metrics-server is available
    if kubectl top pods -n "$ETCD_NAMESPACE" &> /dev/null; then
        echo ""
        echo "Current resource usage:"
        kubectl top pods -n "$ETCD_NAMESPACE" | grep "etcd"
    fi
fi

echo ""
echo "10. Recent etcd Errors..."
echo "-----------------------"

if [ "$etcd_count" -gt 0 ]; then
    # Check logs for errors
    first_etcd_pod=$(echo "$ETCD_PODS" | jq -r '.items[0].metadata.name')
    
    echo "Checking recent logs for errors..."
    error_count=$(kubectl logs -n "$ETCD_NAMESPACE" "$first_etcd_pod" --tail=200 2>/dev/null | grep -ciE "error|fail|panic|fatal" || echo "0")
    
    if [ "$error_count" -gt 0 ]; then
        echo -e "${YELLOW}⚠ Found $error_count error messages in recent logs${NC}"
        echo "Recent errors:"
        kubectl logs -n "$ETCD_NAMESPACE" "$first_etcd_pod" --tail=200 2>/dev/null | grep -iE "error|fail|panic|fatal" | tail -5
    else
        echo -e "${GREEN}✓ No errors found in recent logs${NC}"
    fi
    
    # Check for specific performance warnings
    slow_queries=$(kubectl logs -n "$ETCD_NAMESPACE" "$first_etcd_pod" --tail=200 2>/dev/null | grep -c "slow fdatasync" || echo "0")
    if [ "$slow_queries" -gt 0 ]; then
        echo -e "${YELLOW}⚠ Found $slow_queries slow fdatasync warnings (disk performance issue)${NC}"
    fi
fi

echo ""
echo "======================================"
echo "etcd Health Check Complete"
echo ""
echo "Summary:"
if [ "$EXTERNAL_ETCD" = true ]; then
    echo "- Configuration: External etcd (not managed by Kubernetes)"
else
    echo "- etcd pods: $running_count/$etcd_count running"
fi
[ "$ETCDCTL_AVAILABLE" = true ] && echo "- Cluster health: Check results above"
echo "- Backup status: $backup_cronjobs CronJobs, $backup_jobs Jobs"
echo "======================================"
#!/bin/bash

# Kube-proxy Health Check Script
# This script performs detailed analysis of kube-proxy networking component

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
echo "Kube-proxy Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

echo "1. Kube-proxy Deployment Status"
echo "-----------------------------"

# Check if kube-proxy is deployed as DaemonSet
kube_proxy_ds=$(kubectl get daemonset -n kube-system kube-proxy -o json 2>/dev/null)

if [ -n "$kube_proxy_ds" ] && [ "$kube_proxy_ds" != "null" ]; then
    echo "Kube-proxy deployed as DaemonSet"
    
    desired=$(echo "$kube_proxy_ds" | jq '.status.desiredNumberScheduled')
    current=$(echo "$kube_proxy_ds" | jq '.status.currentNumberScheduled')
    ready=$(echo "$kube_proxy_ds" | jq '.status.numberReady')
    available=$(echo "$kube_proxy_ds" | jq '.status.numberAvailable')
    
    echo "  Desired: $desired"
    echo "  Current: $current"
    echo "  Ready: $ready"
    echo "  Available: $available"
    
    if [ "$ready" -eq "$desired" ]; then
        echo -e "${GREEN}✓ All kube-proxy pods are ready${NC}"
    else
        echo -e "${YELLOW}⚠ Only $ready/$desired kube-proxy pods are ready${NC}"
    fi
else
    # Check for static pods
    static_pods=$(kubectl get pods -n kube-system -o json | jq '[.items[] | select(.metadata.name | startswith("kube-proxy"))] | length')
    if [ "$static_pods" -gt 0 ]; then
        echo "Kube-proxy running as static pods: $static_pods found"
    else
        echo -e "${RED}✗ Kube-proxy not found as DaemonSet or static pods${NC}"
    fi
fi

echo ""
echo "2. Kube-proxy Pod Health"
echo "----------------------"

# Get all kube-proxy pods
kube_proxy_pods=$(kubectl get pods -n kube-system -l k8s-app=kube-proxy -o json 2>/dev/null)
pod_count=$(echo "$kube_proxy_pods" | jq '.items | length')

if [ "$pod_count" -eq 0 ]; then
    # Try alternative label
    kube_proxy_pods=$(kubectl get pods -n kube-system -o json | jq '.items[] | select(.metadata.name | startswith("kube-proxy"))' | jq -s '{"items": .}')
    pod_count=$(echo "$kube_proxy_pods" | jq '.items | length')
fi

echo "Total kube-proxy pods: $pod_count"

if [ "$pod_count" -gt 0 ]; then
    # Check pod status
    running_pods=$(echo "$kube_proxy_pods" | jq '[.items[] | select(.status.phase == "Running")] | length')
    
    echo "Running pods: $running_pods"
    
    # Check for restarts
    echo ""
    echo "Pod restart analysis:"
    high_restart_pods=0
    
    for i in $(seq 0 $((pod_count - 1))); do
        pod=$(echo "$kube_proxy_pods" | jq ".items[$i]")
        pod_name=$(echo "$pod" | jq -r '.metadata.name')
        node_name=$(echo "$pod" | jq -r '.spec.nodeName')
        restart_count=$(echo "$pod" | jq '.status.containerStatuses[0].restartCount // 0')
        
        if [ "$restart_count" -gt 5 ]; then
            echo -e "  ${YELLOW}$pod_name (node: $node_name): $restart_count restarts${NC}"
            ((high_restart_pods++))
        elif [ "$restart_count" -gt 0 ]; then
            echo "  $pod_name (node: $node_name): $restart_count restarts"
        fi
    done
    
    if [ "$high_restart_pods" -eq 0 ] && [ "$running_pods" -eq "$pod_count" ]; then
        echo -e "${GREEN}✓ All kube-proxy pods stable${NC}"
    fi
fi

echo ""
echo "3. Kube-proxy Mode Detection"
echo "--------------------------"

# Try to detect kube-proxy mode
if [ "$pod_count" -gt 0 ]; then
    first_pod=$(echo "$kube_proxy_pods" | jq -r '.items[0].metadata.name')
    
    # Check ConfigMap for mode
    kube_proxy_cm=$(kubectl get configmap -n kube-system kube-proxy -o json 2>/dev/null)
    
    if [ -n "$kube_proxy_cm" ] && [ "$kube_proxy_cm" != "null" ]; then
        mode=$(echo "$kube_proxy_cm" | jq -r '.data.config' | grep -oP 'mode:\s*"\K[^"]+' || echo "")
        
        if [ -z "$mode" ]; then
            mode=$(echo "$kube_proxy_cm" | jq -r '.data.config' | grep -oP 'mode:\s*\K\w+' || echo "iptables")
        fi
        
        echo "Proxy mode: ${mode:-iptables (default)}"
        
        case "$mode" in
            "ipvs")
                echo -e "${GREEN}✓ Using IPVS mode (better performance)${NC}"
                
                # Check if IPVS kernel modules are loaded
                echo ""
                echo "Checking IPVS prerequisites..."
                
                # Check for ipvsadm in pod
                if kubectl exec -n kube-system "$first_pod" -- which ipvsadm &> /dev/null; then
                    echo -e "${GREEN}✓ ipvsadm available${NC}"
                else
                    echo -e "${YELLOW}⚠ ipvsadm not found in pod${NC}"
                fi
                ;;
            "iptables"|"")
                echo "✓ Using iptables mode (default)"
                ;;
            "userspace")
                echo -e "${YELLOW}⚠ Using userspace mode (deprecated, poor performance)${NC}"
                ;;
            *)
                echo "Unknown mode: $mode"
                ;;
        esac
    else
        echo "Unable to determine proxy mode from ConfigMap"
    fi
fi

echo ""
echo "4. Service and Endpoint Sync"
echo "--------------------------"

# Check services and endpoints
total_services=$(kubectl get services --all-namespaces -o json | jq '.items | length')
total_endpoints=$(kubectl get endpoints --all-namespaces -o json | jq '.items | length')

echo "Total services: $total_services"
echo "Total endpoints: $total_endpoints"

# Check for services without endpoints
services_without_endpoints=0
services=$(kubectl get services --all-namespaces -o json)

for i in $(seq 0 $((total_services - 1))); do
    svc=$(echo "$services" | jq ".items[$i]")
    svc_name=$(echo "$svc" | jq -r '.metadata.name')
    svc_namespace=$(echo "$svc" | jq -r '.metadata.namespace')
    svc_type=$(echo "$svc" | jq -r '.spec.type')
    
    # Skip ExternalName services
    if [ "$svc_type" != "ExternalName" ]; then
        endpoints=$(kubectl get endpoints -n "$svc_namespace" "$svc_name" -o json 2>/dev/null | jq '.subsets[0].addresses | length' || echo "0")
        
        if [ "$endpoints" -eq 0 ] && [ "$svc_name" != "kubernetes" ]; then
            ((services_without_endpoints++))
        fi
    fi
done

if [ "$services_without_endpoints" -gt 0 ]; then
    echo -e "${YELLOW}⚠ Services without endpoints: $services_without_endpoints${NC}"
else
    echo -e "${GREEN}✓ All services have endpoints${NC}"
fi

echo ""
echo "5. Kube-proxy Configuration Analysis"
echo "----------------------------------"

if [ -n "$kube_proxy_cm" ] && [ "$kube_proxy_cm" != "null" ]; then
    echo "Configuration parameters:"
    
    # Extract key configurations
    cluster_cidr=$(echo "$kube_proxy_cm" | jq -r '.data.config' | grep -oP 'clusterCIDR:\s*"\K[^"]+' || echo "not set")
    echo "  Cluster CIDR: $cluster_cidr"
    
    # Check for nodePort range
    nodeport_addresses=$(echo "$kube_proxy_cm" | jq -r '.data.config' | grep -oP 'nodePortAddresses:\s*\[\K[^\]]+' || echo "all")
    echo "  NodePort addresses: ${nodeport_addresses:-all}"
    
    # Metrics bind address
    metrics_addr=$(echo "$kube_proxy_cm" | jq -r '.data.config' | grep -oP 'metricsBindAddress:\s*"\K[^"]+' || echo "127.0.0.1:10249")
    echo "  Metrics address: $metrics_addr"
    
    # Sync period
    sync_period=$(echo "$kube_proxy_cm" | jq -r '.data.config' | grep -oP 'syncPeriod:\s*"\K[^"]+' || echo "30s")
    echo "  Sync period: $sync_period"
fi

echo ""
echo "6. Network Rules Analysis"
echo "-----------------------"

# For IPVS mode, check IPVS rules
if [ "${mode:-iptables}" = "ipvs" ] && [ "$pod_count" -gt 0 ]; then
    echo "Checking IPVS rules..."
    
    # Get rule count from first pod
    ipvs_rules=$(kubectl exec -n kube-system "$first_pod" -- ipvsadm -L -n 2>/dev/null | grep -c "^TCP\|^UDP" || echo "0")
    echo "  IPVS services configured: $ipvs_rules"
    
    if [ "$ipvs_rules" -gt 0 ]; then
        echo -e "${GREEN}✓ IPVS rules present${NC}"
    else
        echo -e "${YELLOW}⚠ No IPVS rules found${NC}"
    fi
fi

# For iptables mode, check rule counts
if [ "${mode:-iptables}" = "iptables" ] && [ "$pod_count" -gt 0 ]; then
    echo "Checking iptables rules..."
    
    # Count kube-proxy chains
    kube_chains=$(kubectl exec -n kube-system "$first_pod" -- iptables -t nat -L -n 2>/dev/null | grep -c "KUBE-" || echo "0")
    echo "  Kube-proxy chains: $kube_chains"
    
    if [ "$kube_chains" -gt 0 ]; then
        echo -e "${GREEN}✓ iptables rules present${NC}"
    else
        echo -e "${YELLOW}⚠ No kube-proxy iptables rules found${NC}"
    fi
fi

echo ""
echo "7. Service Load Balancing Test"
echo "----------------------------"

# Test service resolution and load balancing
echo "Testing service connectivity..."

# Check if DNS service is accessible
dns_svc=$(kubectl get service -n kube-system kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")

if [ -n "$dns_svc" ]; then
    echo "DNS Service IP: $dns_svc"
    echo -e "${GREEN}✓ DNS service configured${NC}"
else
    echo -e "${YELLOW}⚠ DNS service not found${NC}"
fi

# Check for NodePort services
nodeport_services=$(kubectl get services --all-namespaces -o json | jq '[.items[] | select(.spec.type == "NodePort")] | length')
echo ""
echo "NodePort services: $nodeport_services"

if [ "$nodeport_services" -gt 0 ]; then
    echo "NodePort allocations:"
    kubectl get services --all-namespaces -o json | jq -r '.items[] | select(.spec.type == "NodePort") | "\(.metadata.namespace)/\(.metadata.name): \(.spec.ports[].nodePort)"' | head -5
fi

# Check for LoadBalancer services
lb_services=$(kubectl get services --all-namespaces -o json | jq '[.items[] | select(.spec.type == "LoadBalancer")] | length')
echo ""
echo "LoadBalancer services: $lb_services"

echo ""
echo "8. Kube-proxy Performance Metrics"
echo "-------------------------------"

if [ "$pod_count" -gt 0 ]; then
    echo "Checking kube-proxy metrics..."
    
    # Try to get metrics from kube-proxy
    first_pod=$(echo "$kube_proxy_pods" | jq -r '.items[0].metadata.name')
    
    # Check if metrics endpoint is accessible
    metrics=$(kubectl exec -n kube-system "$first_pod" -- curl -s http://localhost:10249/metrics 2>/dev/null | head -20 || echo "")
    
    if [ -n "$metrics" ]; then
        echo -e "${GREEN}✓ Metrics endpoint accessible${NC}"
        
        # Extract some key metrics
        sync_proxy_rules=$(echo "$metrics" | grep "kubeproxy_sync_proxy_rules_duration_seconds_count" | awk '{print $2}' || echo "0")
        if [ -n "$sync_proxy_rules" ] && [ "$sync_proxy_rules" != "0" ]; then
            echo "  Proxy rules sync count: $sync_proxy_rules"
        fi
    else
        echo -e "${YELLOW}⚠ Metrics endpoint not accessible${NC}"
    fi
fi

echo ""
echo "9. Common Issues Check"
echo "--------------------"

issues_found=0

# Check for conntrack issues
if [ "$pod_count" -gt 0 ]; then
    echo -n "Checking conntrack table: "
    
    conntrack_max=$(kubectl exec -n kube-system "$first_pod" -- cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "0")
    conntrack_count=$(kubectl exec -n kube-system "$first_pod" -- cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "0")
    
    if [ "$conntrack_max" -gt 0 ] && [ "$conntrack_count" -gt 0 ]; then
        usage_percent=$((conntrack_count * 100 / conntrack_max))
        echo "$conntrack_count/$conntrack_max ($usage_percent%)"
        
        if [ "$usage_percent" -gt 80 ]; then
            echo -e "${YELLOW}⚠ High conntrack table usage${NC}"
            ((issues_found++))
        else
            echo -e "${GREEN}✓ Conntrack table usage normal${NC}"
        fi
    else
        echo "Unable to check"
    fi
fi

# Check for kube-proxy events
echo ""
echo "Recent kube-proxy events:"
kube_proxy_events=$(kubectl get events -n kube-system --field-selector involvedObject.name=kube-proxy -o json 2>/dev/null | jq '.items | length' || echo "0")

if [ "$kube_proxy_events" -gt 0 ]; then
    kubectl get events -n kube-system --field-selector involvedObject.name=kube-proxy --sort-by='.lastTimestamp' | tail -5
    ((issues_found++))
else
    echo -e "${GREEN}✓ No kube-proxy events${NC}"
fi

echo ""
echo "10. Recommendations"
echo "-----------------"

recommendations=0

# Mode recommendations
if [ "${mode:-iptables}" = "userspace" ]; then
    echo -e "${RED}• Migrate from userspace to iptables or IPVS mode${NC}"
    ((recommendations++))
fi

if [ "${mode:-iptables}" = "iptables" ] && [ "$total_services" -gt 1000 ]; then
    echo -e "${YELLOW}• Consider using IPVS mode for better performance with $total_services services${NC}"
    ((recommendations++))
fi

# Pod health
if [ "$high_restart_pods" -gt 0 ]; then
    echo -e "${YELLOW}• Investigate $high_restart_pods pods with high restart counts${NC}"
    ((recommendations++))
fi

# Service endpoints
if [ "$services_without_endpoints" -gt 0 ]; then
    echo -e "${YELLOW}• Fix $services_without_endpoints services without endpoints${NC}"
    ((recommendations++))
fi

# Conntrack
if [ "${usage_percent:-0}" -gt 80 ]; then
    echo -e "${YELLOW}• Increase conntrack table size (currently at ${usage_percent}%)${NC}"
    ((recommendations++))
fi

# Configuration
if [ "$cluster_cidr" = "not set" ]; then
    echo -e "${BLUE}• Configure clusterCIDR in kube-proxy for optimal performance${NC}"
    ((recommendations++))
fi

if [ "$recommendations" -eq 0 ]; then
    echo -e "${GREEN}✓ Kube-proxy configuration looks good!${NC}"
fi

echo ""
echo "======================================"
echo "Kube-proxy Health Check Complete"
echo ""
echo "Summary:"
echo "- Mode: ${mode:-iptables}"
echo "- Total pods: $pod_count"
echo "- Services: $total_services"
echo "- Issues found: $issues_found"
echo "- Recommendations: $recommendations"
echo "======================================"
#!/bin/bash

# NGINX Ingress Controller Health Check Script
# This script checks the health status of NGINX Ingress Controller in Kubernetes

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "======================================"
echo "NGINX Ingress Controller Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

# Find ingress-nginx namespace (could be ingress-nginx or nginx-ingress)
NAMESPACE=""
for ns in ingress-nginx nginx-ingress kube-system; do
    if kubectl get namespace "$ns" &> /dev/null && kubectl get pods -n "$ns" -l app.kubernetes.io/name=ingress-nginx &> /dev/null; then
        if [ $(kubectl get pods -n "$ns" -l app.kubernetes.io/name=ingress-nginx -o json | jq '.items | length') -gt 0 ]; then
            NAMESPACE="$ns"
            break
        fi
    fi
done

if [ -z "$NAMESPACE" ]; then
    echo -e "${RED}Error: NGINX Ingress Controller not found in any namespace.${NC}"
    echo "Checked namespaces: ingress-nginx, nginx-ingress, kube-system"
    exit 1
fi

echo -e "${BLUE}Found NGINX Ingress Controller in namespace: $NAMESPACE${NC}"
echo ""

echo "1. Checking NGINX Ingress Controller Pods..."
echo "------------------------------------------"
controller_pods=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller -o json)
controller_count=$(echo "$controller_pods" | jq '.items | length')

if [ "$controller_count" -eq 0 ]; then
    # Try alternative label
    controller_pods=$(kubectl get pods -n "$NAMESPACE" -l app=nginx-ingress,component=controller -o json)
    controller_count=$(echo "$controller_pods" | jq '.items | length')
fi

if [ "$controller_count" -eq 0 ]; then
    echo -e "${RED}✗ No NGINX Ingress Controller pods found${NC}"
else
    controller_ready=$(echo "$controller_pods" | jq '[.items[] | select(.status.phase == "Running" and all(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length')
    
    echo -e "Found $controller_count NGINX Ingress Controller pod(s)"
    if [ "$controller_ready" -eq "$controller_count" ]; then
        echo -e "${GREEN}✓ All Controller pods are Running and Ready${NC}"
    else
        echo -e "${YELLOW}⚠ Only $controller_ready/$controller_count Controller pods are Running and Ready${NC}"
        echo ""
        echo "Pod Status:"
        kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller
    fi
    
    # Check pod resources
    echo ""
    echo "Controller Pod Resources:"
    echo "$controller_pods" | jq -r '.items[] | "\(.metadata.name): CPU: \(.spec.containers[0].resources.requests.cpu // "not set") / \(.spec.containers[0].resources.limits.cpu // "not set"), Memory: \(.spec.containers[0].resources.requests.memory // "not set") / \(.spec.containers[0].resources.limits.memory // "not set")"'
fi
echo ""

echo "2. Checking NGINX Ingress Controller Deployment/DaemonSet..."
echo "---------------------------------------------------------"
# Check if it's a Deployment
deployment=$(kubectl get deployment -n "$NAMESPACE" -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller -o json 2>/dev/null)
if [ "$(echo "$deployment" | jq '.items | length')" -gt 0 ]; then
    replicas=$(echo "$deployment" | jq '.items[0].spec.replicas')
    ready_replicas=$(echo "$deployment" | jq '.items[0].status.readyReplicas // 0')
    
    echo "Deployment found:"
    if [ "$ready_replicas" -eq "$replicas" ]; then
        echo -e "${GREEN}✓ Deployment: $ready_replicas/$replicas replicas ready${NC}"
    else
        echo -e "${YELLOW}⚠ Deployment: $ready_replicas/$replicas replicas ready${NC}"
    fi
else
    # Check if it's a DaemonSet
    daemonset=$(kubectl get daemonset -n "$NAMESPACE" -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller -o json 2>/dev/null)
    if [ "$(echo "$daemonset" | jq '.items | length')" -gt 0 ]; then
        desired=$(echo "$daemonset" | jq '.items[0].status.desiredNumberScheduled')
        ready=$(echo "$daemonset" | jq '.items[0].status.numberReady // 0')
        
        echo "DaemonSet found:"
        if [ "$ready" -eq "$desired" ]; then
            echo -e "${GREEN}✓ DaemonSet: $ready/$desired pods ready${NC}"
        else
            echo -e "${YELLOW}⚠ DaemonSet: $ready/$desired pods ready${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ No Deployment or DaemonSet found for NGINX Ingress Controller${NC}"
    fi
fi
echo ""

echo "3. Checking NGINX Ingress Service..."
echo "-----------------------------------"
service=$(kubectl get service -n "$NAMESPACE" -l app.kubernetes.io/name=ingress-nginx,app.kubernetes.io/component=controller -o json)
if [ "$(echo "$service" | jq '.items | length')" -gt 0 ]; then
    echo "$service" | jq -r '.items[] | 
        "Service: \(.metadata.name)",
        "Type: \(.spec.type)",
        "ClusterIP: \(.spec.clusterIP)",
        if .spec.type == "LoadBalancer" then
            "External IP: \(.status.loadBalancer.ingress[0].ip // .status.loadBalancer.ingress[0].hostname // "pending")"
        else empty end,
        "Ports: \(.spec.ports | map("\(.name):\(.port)") | join(", "))",
        ""'
else
    echo -e "${YELLOW}⚠ No NGINX Ingress Service found${NC}"
fi

echo "4. Checking Ingress Classes..."
echo "-----------------------------"
ingress_classes=$(kubectl get ingressclass -o json | jq -r '.items[] | select(.spec.controller == "k8s.io/ingress-nginx") | .metadata.name')
if [ -z "$ingress_classes" ]; then
    echo -e "${YELLOW}⚠ No NGINX Ingress Classes found${NC}"
else
    echo -e "${GREEN}✓ NGINX Ingress Classes found:${NC}"
    echo "$ingress_classes"
    
    # Check for default class
    default_class=$(kubectl get ingressclass -o json | jq -r '.items[] | select(.spec.controller == "k8s.io/ingress-nginx" and .metadata.annotations["ingressclass.kubernetes.io/is-default-class"] == "true") | .metadata.name')
    if [ -n "$default_class" ]; then
        echo -e "${GREEN}✓ Default ingress class: $default_class${NC}"
    fi
fi
echo ""

echo "5. Checking Ingress Resources..."
echo "-------------------------------"
total_ingresses=$(kubectl get ingress --all-namespaces -o json | jq '.items | length')
nginx_ingresses=$(kubectl get ingress --all-namespaces -o json | jq '[.items[] | select(.spec.ingressClassName == "nginx" or .metadata.annotations["kubernetes.io/ingress.class"] == "nginx")] | length')

echo "Total Ingress resources: $total_ingresses"
if [ "$nginx_ingresses" -gt 0 ]; then
    echo -e "${GREEN}✓ NGINX Ingress resources: $nginx_ingresses${NC}"
    
    # List ingresses with issues
    echo ""
    echo "Checking Ingress health..."
    kubectl get ingress --all-namespaces -o json | jq -r '
        .items[] | 
        select(.spec.ingressClassName == "nginx" or .metadata.annotations["kubernetes.io/ingress.class"] == "nginx") |
        {
            namespace: .metadata.namespace,
            name: .metadata.name,
            hosts: (.spec.rules | map(.host) | join(", ")),
            hasAddress: (if .status.loadBalancer.ingress then true else false end)
        } |
        if .hasAddress then
            "\(.namespace)/\(.name): ✓ Ready - Hosts: \(.hosts)"
        else
            "\(.namespace)/\(.name): ⚠ No address assigned - Hosts: \(.hosts)"
        end'
else
    echo -e "${YELLOW}⚠ No NGINX Ingress resources found${NC}"
fi
echo ""

echo "6. Checking NGINX Configuration..."
echo "---------------------------------"
if [ "$controller_count" -gt 0 ]; then
    first_pod=$(echo "$controller_pods" | jq -r '.items[0].metadata.name')
    echo "Testing NGINX configuration in pod: $first_pod"
    
    if kubectl exec -n "$NAMESPACE" "$first_pod" -- nginx -T &> /dev/null; then
        echo -e "${GREEN}✓ NGINX configuration is valid${NC}"
        
        # Get some basic stats
        backends=$(kubectl exec -n "$NAMESPACE" "$first_pod" -- sh -c 'grep -c "upstream" /etc/nginx/nginx.conf 2>/dev/null || echo 0' 2>/dev/null)
        servers=$(kubectl exec -n "$NAMESPACE" "$first_pod" -- sh -c 'grep -c "server {" /etc/nginx/nginx.conf 2>/dev/null || echo 0' 2>/dev/null)
        
        echo "Configured upstreams: $backends"
        echo "Configured servers: $servers"
    else
        echo -e "${RED}✗ NGINX configuration test failed${NC}"
    fi
fi
echo ""

echo "7. Checking Webhook Configuration..."
echo "-----------------------------------"
webhook=$(kubectl get validatingwebhookconfiguration -l app.kubernetes.io/name=ingress-nginx -o json)
if [ "$(echo "$webhook" | jq '.items | length')" -gt 0 ]; then
    webhook_name=$(echo "$webhook" | jq -r '.items[0].metadata.name')
    echo -e "${GREEN}✓ Validating webhook found: $webhook_name${NC}"
    
    # Check webhook service
    webhook_service=$(echo "$webhook" | jq -r '.items[0].webhooks[0].clientConfig.service | "\(.namespace)/\(.name):\(.port)"')
    echo "Webhook service: $webhook_service"
else
    echo -e "${YELLOW}⚠ No validating webhook found (admission control may not be working)${NC}"
fi
echo ""

echo "8. Recent Events..."
echo "-----------------"
recent_events=$(kubectl get events -n "$NAMESPACE" --field-selector type=Warning --sort-by='.lastTimestamp' -o json | jq -r '.items | sort_by(.lastTimestamp) | reverse | .[0:5] | .[] | "\(.lastTimestamp): \(.reason) - \(.message)"')
if [ -n "$recent_events" ]; then
    echo -e "${YELLOW}Recent warning events:${NC}"
    echo "$recent_events"
else
    echo -e "${GREEN}✓ No recent warning events${NC}"
fi
echo ""

echo "======================================"
echo "NGINX Ingress Health Check Complete"
echo "======================================"
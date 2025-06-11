#!/bin/bash

# Longhorn Storage Health Check Script
# This script checks the health status of Longhorn storage system in Kubernetes

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "======================================"
echo "Longhorn Storage Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

# Check if longhorn namespace exists
if ! kubectl get namespace longhorn-system &> /dev/null; then
    echo -e "${RED}Error: Longhorn namespace 'longhorn-system' not found.${NC}"
    exit 1
fi

echo "1. Checking Longhorn Manager Pods..."
echo "-----------------------------------"
manager_pods=$(kubectl get pods -n longhorn-system -l app=longhorn-manager -o json)
manager_count=$(echo "$manager_pods" | jq '.items | length')
manager_ready=$(echo "$manager_pods" | jq '[.items[] | select(.status.phase == "Running")] | length')

if [ "$manager_count" -eq 0 ]; then
    echo -e "${RED}✗ No Longhorn Manager pods found${NC}"
else
    echo -e "Found $manager_count Longhorn Manager pod(s)"
    if [ "$manager_ready" -eq "$manager_count" ]; then
        echo -e "${GREEN}✓ All Manager pods are Running${NC}"
    else
        echo -e "${YELLOW}⚠ Only $manager_ready/$manager_count Manager pods are Running${NC}"
        kubectl get pods -n longhorn-system -l app=longhorn-manager
    fi
fi
echo ""

echo "2. Checking Longhorn Engine Image DaemonSet..."
echo "--------------------------------------------"
engine_ds=$(kubectl get daemonset -n longhorn-system -l app=longhorn-manager -o json)
if [ "$(echo "$engine_ds" | jq '.items | length')" -gt 0 ]; then
    desired=$(echo "$engine_ds" | jq '.items[0].status.desiredNumberScheduled')
    ready=$(echo "$engine_ds" | jq '.items[0].status.numberReady')
    if [ "$desired" -eq "$ready" ]; then
        echo -e "${GREEN}✓ Engine Image DaemonSet: $ready/$desired pods ready${NC}"
    else
        echo -e "${YELLOW}⚠ Engine Image DaemonSet: $ready/$desired pods ready${NC}"
    fi
else
    echo -e "${YELLOW}⚠ No Engine Image DaemonSet found${NC}"
fi
echo ""

echo "3. Checking Longhorn CSI Driver..."
echo "--------------------------------"
csi_driver=$(kubectl get pods -n longhorn-system -l app=csi-provisioner -o json)
csi_count=$(echo "$csi_driver" | jq '.items | length')
csi_ready=$(echo "$csi_driver" | jq '[.items[] | select(.status.phase == "Running")] | length')

if [ "$csi_count" -eq 0 ]; then
    echo -e "${RED}✗ No CSI provisioner pods found${NC}"
else
    if [ "$csi_ready" -eq "$csi_count" ]; then
        echo -e "${GREEN}✓ CSI provisioner pods: $csi_ready/$csi_count Running${NC}"
    else
        echo -e "${YELLOW}⚠ CSI provisioner pods: $csi_ready/$csi_count Running${NC}"
    fi
fi

csi_attacher=$(kubectl get pods -n longhorn-system -l app=csi-attacher -o json)
attacher_count=$(echo "$csi_attacher" | jq '.items | length')
attacher_ready=$(echo "$csi_attacher" | jq '[.items[] | select(.status.phase == "Running")] | length')

if [ "$attacher_count" -gt 0 ]; then
    if [ "$attacher_ready" -eq "$attacher_count" ]; then
        echo -e "${GREEN}✓ CSI attacher pods: $attacher_ready/$attacher_count Running${NC}"
    else
        echo -e "${YELLOW}⚠ CSI attacher pods: $attacher_ready/$attacher_count Running${NC}"
    fi
fi
echo ""

echo "4. Checking Longhorn Volumes..."
echo "------------------------------"
volumes=$(kubectl get volumes.longhorn.io -n longhorn-system -o json 2>/dev/null)
if [ $? -eq 0 ]; then
    total_volumes=$(echo "$volumes" | jq '.items | length')
    healthy_volumes=$(echo "$volumes" | jq '[.items[] | select(.status.state == "attached" or .status.state == "detached") | select(.status.robustness == "healthy")] | length')
    degraded_volumes=$(echo "$volumes" | jq '[.items[] | select(.status.robustness == "degraded")] | length')
    faulted_volumes=$(echo "$volumes" | jq '[.items[] | select(.status.robustness == "faulted")] | length')
    
    echo "Total volumes: $total_volumes"
    if [ "$healthy_volumes" -gt 0 ]; then
        echo -e "${GREEN}✓ Healthy volumes: $healthy_volumes${NC}"
    fi
    if [ "$degraded_volumes" -gt 0 ]; then
        echo -e "${YELLOW}⚠ Degraded volumes: $degraded_volumes${NC}"
        echo "Degraded volumes:"
        kubectl get volumes.longhorn.io -n longhorn-system -o json | jq -r '.items[] | select(.status.robustness == "degraded") | .metadata.name'
    fi
    if [ "$faulted_volumes" -gt 0 ]; then
        echo -e "${RED}✗ Faulted volumes: $faulted_volumes${NC}"
        echo "Faulted volumes:"
        kubectl get volumes.longhorn.io -n longhorn-system -o json | jq -r '.items[] | select(.status.robustness == "faulted") | .metadata.name'
    fi
else
    echo -e "${YELLOW}⚠ Unable to check Longhorn volumes (CRDs might not be installed)${NC}"
fi
echo ""

echo "5. Checking Longhorn Nodes..."
echo "---------------------------"
nodes=$(kubectl get nodes.longhorn.io -n longhorn-system -o json 2>/dev/null)
if [ $? -eq 0 ]; then
    total_nodes=$(echo "$nodes" | jq '.items | length')
    ready_nodes=$(echo "$nodes" | jq '[.items[] | select(.status.conditions[] | select(.type == "Ready" and .status == "True"))] | length')
    
    echo "Total Longhorn nodes: $total_nodes"
    if [ "$ready_nodes" -eq "$total_nodes" ]; then
        echo -e "${GREEN}✓ All nodes are ready: $ready_nodes/$total_nodes${NC}"
    else
        echo -e "${YELLOW}⚠ Only $ready_nodes/$total_nodes nodes are ready${NC}"
        echo "Not ready nodes:"
        kubectl get nodes.longhorn.io -n longhorn-system -o json | jq -r '.items[] | select(.status.conditions[] | select(.type == "Ready" and .status != "True")) | .metadata.name'
    fi
else
    echo -e "${YELLOW}⚠ Unable to check Longhorn nodes (CRDs might not be installed)${NC}"
fi
echo ""

echo "6. Checking Storage Classes..."
echo "----------------------------"
storage_classes=$(kubectl get storageclass -o json | jq -r '.items[] | select(.provisioner == "driver.longhorn.io") | .metadata.name')
if [ -z "$storage_classes" ]; then
    echo -e "${YELLOW}⚠ No Longhorn storage classes found${NC}"
else
    echo -e "${GREEN}✓ Longhorn storage classes found:${NC}"
    echo "$storage_classes"
fi
echo ""

echo "7. Checking Disk Space..."
echo "-----------------------"
if kubectl get nodes.longhorn.io -n longhorn-system &> /dev/null; then
    kubectl get nodes.longhorn.io -n longhorn-system -o json | jq -r '.items[] | 
        .metadata.name as $node | 
        .status.diskStatus | to_entries[] | 
        "\($node): \(.key) - Available: \(.value.storageAvailable / 1073741824 | floor)GB / Total: \(.value.storageMaximum / 1073741824 | floor)GB (\(.value.storageAvailable / .value.storageMaximum * 100 | floor)% free)"'
else
    echo -e "${YELLOW}⚠ Unable to check disk space${NC}"
fi
echo ""

echo "======================================"
echo "Longhorn Health Check Complete"
echo "======================================"
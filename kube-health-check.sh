#!/bin/bash

# Kubernetes Comprehensive Health Check Master Script
# This script runs all available health checks and provides a summary report

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
RUN_ALL=false
SELECTED_CHECKS=()
OUTPUT_FILE=""
VERBOSE=false
PARALLEL=false

# Available health check scripts
declare -A HEALTH_CHECKS=(
    ["cluster"]="check-k8s-health-enhanced.sh:Enhanced Kubernetes Cluster Health"
    ["nodes"]="check-node-health.sh:Node Health and Resources"
    ["storage"]="check-storage-health.sh:Persistent Storage Health"
    ["network"]="check-network-connectivity.sh:Network Connectivity Test"
    ["security"]="check-pod-security.sh:Pod Security and Compliance"
    ["longhorn"]="check-longhorn.sh:Longhorn Storage System"
    ["nginx"]="check-nginx-ingress.sh:NGINX Ingress Controller"
    ["loki"]="check-loki.sh:Loki Logging System"
    ["cilium"]="check-cilium.sh:Cilium CNI"
    ["cilium-envoy"]="check-cilium-envoy.sh:Cilium Envoy Proxy"
    ["etcd"]="check-etcd.sh:etcd Key-Value Store"
    ["coredns"]="check-coredns.sh:CoreDNS"
    ["metrics"]="check-metrics-server.sh:Metrics Server"
    ["cert-manager"]="check-cert-manager.sh:cert-manager"
    ["hostport"]="check-hostport-conflicts.sh:Host Port Conflicts"
)

# Usage function
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [CHECKS...]

Kubernetes Comprehensive Health Check Tool

OPTIONS:
    -a, --all           Run all available health checks
    -o, --output FILE   Save output to file
    -v, --verbose       Show detailed output
    -p, --parallel      Run checks in parallel (experimental)
    -l, --list          List available health checks
    -h, --help          Show this help message

CHECKS:
    Specify one or more check names to run specific checks.
    Available checks: ${!HEALTH_CHECKS[@]}

EXAMPLES:
    # Run all health checks
    $0 --all

    # Run specific checks
    $0 cluster nodes storage

    # Run all checks and save to file
    $0 --all --output health-report.txt

    # List available checks
    $0 --list

EOF
    exit 1
}

# List available checks
list_checks() {
    echo "Available Health Checks:"
    echo "======================="
    echo ""
    
    for check in "${!HEALTH_CHECKS[@]}"; do
        IFS=':' read -r script description <<< "${HEALTH_CHECKS[$check]}"
        printf "%-15s - %s\n" "$check" "$description"
    done
    echo ""
    echo "Use '$0 <check-name>' to run specific checks"
    echo "Use '$0 --all' to run all checks"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -a|--all)
            RUN_ALL=true
            shift
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -p|--parallel)
            PARALLEL=true
            shift
            ;;
        -l|--list)
            list_checks
            exit 0
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            ;;
        *)
            SELECTED_CHECKS+=("$1")
            shift
            ;;
    esac
done

# Determine which checks to run
if [ "$RUN_ALL" = true ]; then
    SELECTED_CHECKS=("${!HEALTH_CHECKS[@]}")
elif [ ${#SELECTED_CHECKS[@]} -eq 0 ]; then
    echo "No checks specified. Use --all or specify check names."
    echo ""
    list_checks
    exit 1
fi

# Validate selected checks
for check in "${SELECTED_CHECKS[@]}"; do
    if [[ ! -v HEALTH_CHECKS[$check] ]]; then
        echo -e "${RED}Error: Unknown check '$check'${NC}"
        echo "Use --list to see available checks"
        exit 1
    fi
done

# Function to run a single check
run_check() {
    local check_name=$1
    local script_info="${HEALTH_CHECKS[$check_name]}"
    IFS=':' read -r script_file description <<< "$script_info"
    local script_path="$SCRIPT_DIR/$script_file"
    
    if [ ! -f "$script_path" ]; then
        # Try without .sh extension for backward compatibility
        script_path="$SCRIPT_DIR/${script_file%.sh}"
        if [ ! -f "$script_path" ]; then
            echo -e "${RED}✗ Script not found: $script_file${NC}"
            return 1
        fi
    fi
    
    if [ ! -x "$script_path" ]; then
        chmod +x "$script_path"
    fi
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Running: $description${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    local start_time=$(date +%s)
    
    if [ "$VERBOSE" = true ]; then
        "$script_path" 2>&1
    else
        "$script_path" 2>&1 | grep -E "^(Summary:|━|✓|✗|⚠|•|[0-9]+\.|^$)" || true
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    echo ""
    echo -e "${BLUE}Check completed in ${duration}s${NC}"
    echo ""
    
    return 0
}

# Function to run checks in parallel
run_parallel_checks() {
    local pids=()
    local check_names=()
    
    for check in "${SELECTED_CHECKS[@]}"; do
        {
            run_check "$check" > "/tmp/kube-health-$check-$$.log" 2>&1
        } &
        pids+=($!)
        check_names+=("$check")
    done
    
    # Wait for all checks to complete
    for i in "${!pids[@]}"; do
        wait "${pids[$i]}"
        cat "/tmp/kube-health-${check_names[$i]}-$$.log"
        rm -f "/tmp/kube-health-${check_names[$i]}-$$.log"
    done
}

# Main execution
main() {
    local start_time=$(date +%s)
    
    # Header
    echo ""
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║         Kubernetes Comprehensive Health Check Report              ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Date: $(date)"
    echo "Cluster: $(kubectl config current-context 2>/dev/null || echo "Unknown")"
    echo "Checks to run: ${#SELECTED_CHECKS[@]}"
    echo ""
    
    # Check kubectl availability
    if ! command -v kubectl &> /dev/null; then
        echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
        exit 1
    fi
    
    # Check cluster connectivity
    echo -n "Checking cluster connectivity... "
    if kubectl cluster-info &> /dev/null; then
        echo -e "${GREEN}✓ Connected${NC}"
    else
        echo -e "${RED}✗ Cannot connect to cluster${NC}"
        exit 1
    fi
    echo ""
    
    # Run health checks
    if [ "$PARALLEL" = true ]; then
        echo -e "${YELLOW}Running checks in parallel...${NC}"
        echo ""
        run_parallel_checks
    else
        local completed=0
        local failed=0
        
        for check in "${SELECTED_CHECKS[@]}"; do
            if run_check "$check"; then
                ((completed++))
            else
                ((failed++))
            fi
        done
    fi
    
    # Summary
    local end_time=$(date +%s)
    local total_duration=$((end_time - start_time))
    
    echo ""
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║                        Summary Report                             ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Total checks run: ${#SELECTED_CHECKS[@]}"
    echo "Total duration: ${total_duration}s"
    echo ""
    
    # Quick health indicators (if we can gather them)
    if [[ " ${SELECTED_CHECKS[@]} " =~ " cluster " ]] || [ "$RUN_ALL" = true ]; then
        echo "Cluster Health Indicators:"
        
        # Nodes
        ready_nodes=$(kubectl get nodes -o json | jq '[.items[] | select(.status.conditions[] | select(.type == "Ready" and .status == "True"))] | length')
        total_nodes=$(kubectl get nodes -o json | jq '.items | length')
        echo -n "  Nodes: "
        if [ "$ready_nodes" -eq "$total_nodes" ]; then
            echo -e "${GREEN}✓ $ready_nodes/$total_nodes ready${NC}"
        else
            echo -e "${YELLOW}⚠ $ready_nodes/$total_nodes ready${NC}"
        fi
        
        # Pods
        running_pods=$(kubectl get pods --all-namespaces -o json | jq '[.items[] | select(.status.phase == "Running")] | length')
        total_pods=$(kubectl get pods --all-namespaces -o json | jq '.items | length')
        echo "  Pods: $running_pods/$total_pods running"
        
        # System pods
        system_running=$(kubectl get pods -n kube-system -o json | jq '[.items[] | select(.status.phase == "Running")] | length')
        system_total=$(kubectl get pods -n kube-system -o json | jq '.items | length')
        echo -n "  System Pods: "
        if [ "$system_running" -eq "$system_total" ]; then
            echo -e "${GREEN}✓ $system_running/$system_total running${NC}"
        else
            echo -e "${YELLOW}⚠ $system_running/$system_total running${NC}"
        fi
    fi
    
    echo ""
    echo -e "${GREEN}Health check complete!${NC}"
    echo ""
}

# Redirect output if specified
if [ -n "$OUTPUT_FILE" ]; then
    echo "Saving output to: $OUTPUT_FILE"
    main 2>&1 | tee "$OUTPUT_FILE"
else
    main
fi
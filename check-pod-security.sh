#!/bin/bash

# Pod Security and Compliance Check Script
# This script analyzes pod security configurations and compliance

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
echo "Pod Security and Compliance Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

# Initialize counters
total_pods=0
root_pods=0
privileged_pods=0
host_network_pods=0
host_pid_pods=0
host_ipc_pods=0
default_sa_pods=0
no_security_context_pods=0
writable_root_fs_pods=0
cap_add_pods=0
unconfined_seccomp_pods=0
no_resource_limits_pods=0
latest_image_pods=0

echo "1. Pod Security Standards Analysis"
echo "---------------------------------"

# Check if Pod Security Standards are enabled
echo "Checking Pod Security Standards (PSS) configuration..."

namespaces=$(kubectl get namespaces -o json)
pss_namespaces=$(echo "$namespaces" | jq '[.items[] | select(.metadata.labels | keys[] | contains("pod-security.kubernetes.io"))] | length')

if [ "$pss_namespaces" -gt 0 ]; then
    echo -e "${GREEN}✓ Pod Security Standards configured on $pss_namespaces namespace(s)${NC}"
    echo ""
    echo "PSS Configuration by namespace:"
    
    echo "$namespaces" | jq -r '.items[] | 
        select(.metadata.labels | keys[] | contains("pod-security.kubernetes.io")) | 
        .metadata.name as $ns | 
        .metadata.labels | 
        to_entries | 
        map(select(.key | contains("pod-security.kubernetes.io"))) | 
        "\($ns): " + (map("\(.key | split("/")[1])=\(.value)") | join(", "))'
else
    echo -e "${YELLOW}⚠ No Pod Security Standards configured${NC}"
    echo "  Consider implementing PSS for better security posture"
fi

echo ""
echo "2. Security Context Analysis"
echo "--------------------------"

# Get all pods
all_pods=$(kubectl get pods --all-namespaces -o json)
total_pods=$(echo "$all_pods" | jq '.items | length')

echo "Analyzing $total_pods pods across all namespaces..."
echo ""

# Analyze each pod
for i in $(seq 0 $((total_pods - 1))); do
    pod=$(echo "$all_pods" | jq ".items[$i]")
    pod_name=$(echo "$pod" | jq -r '.metadata.name')
    namespace=$(echo "$pod" | jq -r '.metadata.namespace')
    
    # Check for root user
    run_as_root=false
    if echo "$pod" | jq -e '.spec.securityContext.runAsUser == 0' &> /dev/null || \
       echo "$pod" | jq -e '.spec.containers[].securityContext.runAsUser == 0' &> /dev/null; then
        run_as_root=true
        ((root_pods++))
    fi
    
    # Check for no security context
    if ! echo "$pod" | jq -e '.spec.securityContext' &> /dev/null && \
       ! echo "$pod" | jq -e '.spec.containers[].securityContext' &> /dev/null; then
        ((no_security_context_pods++))
    fi
    
    # Check for privileged containers
    if echo "$pod" | jq -e '.spec.containers[].securityContext.privileged == true' &> /dev/null; then
        ((privileged_pods++))
    fi
    
    # Check for host network
    if echo "$pod" | jq -e '.spec.hostNetwork == true' &> /dev/null; then
        ((host_network_pods++))
    fi
    
    # Check for host PID
    if echo "$pod" | jq -e '.spec.hostPID == true' &> /dev/null; then
        ((host_pid_pods++))
    fi
    
    # Check for host IPC
    if echo "$pod" | jq -e '.spec.hostIPC == true' &> /dev/null; then
        ((host_ipc_pods++))
    fi
    
    # Check for default service account
    sa_name=$(echo "$pod" | jq -r '.spec.serviceAccountName // "default"')
    if [ "$sa_name" = "default" ]; then
        ((default_sa_pods++))
    fi
    
    # Check for writable root filesystem
    read_only_root=$(echo "$pod" | jq '[.spec.containers[].securityContext.readOnlyRootFilesystem // false] | all')
    if [ "$read_only_root" != "true" ]; then
        ((writable_root_fs_pods++))
    fi
    
    # Check for added capabilities
    if echo "$pod" | jq -e '.spec.containers[].securityContext.capabilities.add' &> /dev/null; then
        ((cap_add_pods++))
    fi
    
    # Check for seccomp profile
    if ! echo "$pod" | jq -e '.spec.securityContext.seccompProfile' &> /dev/null && \
       ! echo "$pod" | jq -e '.spec.containers[].securityContext.seccompProfile' &> /dev/null; then
        ((unconfined_seccomp_pods++))
    fi
    
    # Check for resource limits
    has_limits=$(echo "$pod" | jq '[.spec.containers[].resources.limits | select(. != null)] | length')
    container_count=$(echo "$pod" | jq '.spec.containers | length')
    if [ "$has_limits" -lt "$container_count" ]; then
        ((no_resource_limits_pods++))
    fi
    
    # Check for latest image tag
    if echo "$pod" | jq -e '.spec.containers[].image' | grep -q ":latest"; then
        ((latest_image_pods++))
    fi
done

# Display results
echo "Security Context Summary:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━"

# Calculate percentages
root_percent=$((root_pods * 100 / total_pods))
privileged_percent=$((privileged_pods * 100 / total_pods))
host_network_percent=$((host_network_pods * 100 / total_pods))
default_sa_percent=$((default_sa_pods * 100 / total_pods))
no_sc_percent=$((no_security_context_pods * 100 / total_pods))

# Display with color coding
echo -e "Running as root: $([ "$root_pods" -eq 0 ] && echo "${GREEN}$root_pods${NC}" || echo "${RED}$root_pods${NC}") ($root_percent%)"
echo -e "Privileged containers: $([ "$privileged_pods" -eq 0 ] && echo "${GREEN}$privileged_pods${NC}" || echo "${RED}$privileged_pods${NC}") ($privileged_percent%)"
echo -e "Host network: $([ "$host_network_pods" -eq 0 ] && echo "${GREEN}$host_network_pods${NC}" || echo "${YELLOW}$host_network_pods${NC}") ($host_network_percent%)"
echo -e "Host PID: $([ "$host_pid_pods" -eq 0 ] && echo "${GREEN}$host_pid_pods${NC}" || echo "${RED}$host_pid_pods${NC}")"
echo -e "Host IPC: $([ "$host_ipc_pods" -eq 0 ] && echo "${GREEN}$host_ipc_pods${NC}" || echo "${RED}$host_ipc_pods${NC}")"
echo -e "Default service account: ${YELLOW}$default_sa_pods${NC} ($default_sa_percent%)"
echo -e "No security context: ${YELLOW}$no_security_context_pods${NC} ($no_sc_percent%)"
echo -e "Writable root filesystem: ${YELLOW}$writable_root_fs_pods${NC}"
echo -e "Added capabilities: $([ "$cap_add_pods" -eq 0 ] && echo "${GREEN}$cap_add_pods${NC}" || echo "${YELLOW}$cap_add_pods${NC}")"
echo -e "Unconfined seccomp: ${YELLOW}$unconfined_seccomp_pods${NC}"
echo -e "No resource limits: ${YELLOW}$no_resource_limits_pods${NC}"
echo -e "Using 'latest' tag: ${YELLOW}$latest_image_pods${NC}"

echo ""
echo "3. High-Risk Pods Detail"
echo "----------------------"

# Show details of high-risk pods
echo "Pods with critical security issues:"
echo ""

# Privileged pods
if [ "$privileged_pods" -gt 0 ]; then
    echo -e "${RED}Privileged Pods:${NC}"
    echo "$all_pods" | jq -r '.items[] | 
        select(.spec.containers[].securityContext.privileged == true) | 
        "\(.metadata.namespace)/\(.metadata.name)"' | head -10
    echo ""
fi

# Root pods
if [ "$root_pods" -gt 10 ]; then
    echo -e "${RED}Pods running as root (sample):${NC}"
    echo "$all_pods" | jq -r '.items[] | 
        select(.spec.securityContext.runAsUser == 0 or .spec.containers[].securityContext.runAsUser == 0) | 
        "\(.metadata.namespace)/\(.metadata.name)"' | head -10
    echo ""
fi

# Host namespace pods
if [ "$host_network_pods" -gt 0 ] || [ "$host_pid_pods" -gt 0 ] || [ "$host_ipc_pods" -gt 0 ]; then
    echo -e "${YELLOW}Pods using host namespaces:${NC}"
    echo "$all_pods" | jq -r '.items[] | 
        select(.spec.hostNetwork == true or .spec.hostPID == true or .spec.hostIPC == true) | 
        "\(.metadata.namespace)/\(.metadata.name): " + 
        (if .spec.hostNetwork then "hostNetwork " else "" end) +
        (if .spec.hostPID then "hostPID " else "" end) +
        (if .spec.hostIPC then "hostIPC" else "" end)' | head -10
    echo ""
fi

echo "4. RBAC Analysis"
echo "---------------"

# Check service accounts
echo "Service Account Analysis:"

# Get all service accounts
service_accounts=$(kubectl get serviceaccounts --all-namespaces -o json)
total_sa=$(echo "$service_accounts" | jq '.items | length')

# Count default service accounts
default_sa=$(echo "$service_accounts" | jq '[.items[] | select(.metadata.name == "default")] | length')
custom_sa=$((total_sa - default_sa))

echo "  Total service accounts: $total_sa"
echo "  Custom service accounts: $custom_sa"
echo "  Default service accounts: $default_sa"

# Check for service accounts with powerful permissions
echo ""
echo "Checking for overly permissive RoleBindings..."

# Get cluster-admin bindings
cluster_admin_subjects=$(kubectl get clusterrolebindings -o json | jq -r '
    .items[] | 
    select(.roleRef.name == "cluster-admin") | 
    .subjects[]? | 
    "\(.kind)/\(.name) in \(.namespace // "cluster-wide")"')

if [ -n "$cluster_admin_subjects" ]; then
    echo -e "${RED}Warning: cluster-admin role bindings found:${NC}"
    echo "$cluster_admin_subjects" | head -10
else
    echo -e "${GREEN}✓ No cluster-admin role bindings to service accounts${NC}"
fi

echo ""
echo "5. Network Policies Coverage"
echo "--------------------------"

# Check network policy coverage
echo "Network Policy Analysis:"

# Get all network policies
netpols=$(kubectl get networkpolicies --all-namespaces -o json)
netpol_count=$(echo "$netpols" | jq '.items | length')

# Get namespaces with network policies
ns_with_netpol=$(echo "$netpols" | jq -r '[.items[].metadata.namespace] | unique | length')

# Total namespaces (excluding system)
user_namespaces=$(kubectl get namespaces -o json | jq '[.items[] | select(.metadata.name | startswith("kube-") | not)] | length')

echo "  Network policies: $netpol_count"
echo "  Namespaces with policies: $ns_with_netpol / $user_namespaces"

if [ "$netpol_count" -eq 0 ]; then
    echo -e "${YELLOW}⚠ No network policies found - network segmentation not enforced${NC}"
else
    # Check for default deny policies
    default_deny=$(echo "$netpols" | jq '[.items[] | select(.spec.podSelector == {} and .spec.policyTypes[]? == "Ingress")] | length')
    echo "  Default deny policies: $default_deny"
fi

echo ""
echo "6. Container Image Security"
echo "-------------------------"

echo "Container Image Analysis:"

# Analyze image sources
all_images=$(echo "$all_pods" | jq -r '.items[].spec.containers[].image' | sort | uniq)
total_images=$(echo "$all_images" | wc -l)

# Count images by registry
echo ""
echo "Images by registry:"
echo "$all_images" | awk -F'/' '{print $1}' | grep -E '\.' | sort | uniq -c | sort -nr | head -10

# Check for unsigned/unverified images
public_registries=$(echo "$all_images" | grep -E '^(docker\.io/|library/|[^/]+/[^/]+$)' | wc -l || echo "0")
if [ "$public_registries" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}⚠ $public_registries images from public registries${NC}"
fi

echo ""
echo "7. Pod Disruption Budget Analysis"
echo "--------------------------------"

# Check PDBs
pdbs=$(kubectl get poddisruptionbudgets --all-namespaces -o json)
pdb_count=$(echo "$pdbs" | jq '.items | length')

echo "Pod Disruption Budgets: $pdb_count"

if [ "$pdb_count" -gt 0 ]; then
    echo ""
    echo "PDB Coverage:"
    # Show PDBs by namespace
    echo "$pdbs" | jq -r '.items | group_by(.metadata.namespace) | .[] | "\(.[0].metadata.namespace): \(length) PDBs"' | head -10
else
    echo -e "${YELLOW}⚠ No Pod Disruption Budgets found${NC}"
    echo "  Consider adding PDBs for critical workloads"
fi

echo ""
echo "8. Security Recommendations"
echo "-------------------------"

recommendations=0

# Critical recommendations
if [ "$privileged_pods" -gt 0 ]; then
    echo -e "${RED}• CRITICAL: Remove privileged flag from $privileged_pods pod(s)${NC}"
    ((recommendations++))
fi

if [ "$host_pid_pods" -gt 0 ]; then
    echo -e "${RED}• CRITICAL: $host_pid_pods pod(s) using hostPID - high security risk${NC}"
    ((recommendations++))
fi

# High priority recommendations
if [ "$root_pods" -gt $((total_pods / 4)) ]; then
    echo -e "${YELLOW}• HIGH: $root_pods pods run as root - use non-root users${NC}"
    ((recommendations++))
fi

if [ "$no_security_context_pods" -gt $((total_pods / 3)) ]; then
    echo -e "${YELLOW}• HIGH: $no_security_context_pods pods lack security context${NC}"
    ((recommendations++))
fi

# Medium priority recommendations
if [ "$default_sa_pods" -gt $((total_pods / 2)) ]; then
    echo -e "${YELLOW}• MEDIUM: $default_sa_pods pods use default service account${NC}"
    ((recommendations++))
fi

if [ "$no_resource_limits_pods" -gt $((total_pods / 3)) ]; then
    echo -e "${YELLOW}• MEDIUM: $no_resource_limits_pods pods lack resource limits${NC}"
    ((recommendations++))
fi

if [ "$netpol_count" -eq 0 ]; then
    echo -e "${YELLOW}• MEDIUM: Implement network policies for network segmentation${NC}"
    ((recommendations++))
fi

# General recommendations
if [ "$pss_namespaces" -eq 0 ]; then
    echo -e "${BLUE}• Implement Pod Security Standards${NC}"
    ((recommendations++))
fi

if [ "$latest_image_pods" -gt 0 ]; then
    echo -e "${BLUE}• Use specific image tags instead of 'latest'${NC}"
    ((recommendations++))
fi

if [ "$unconfined_seccomp_pods" -gt $((total_pods / 2)) ]; then
    echo -e "${BLUE}• Enable seccomp profiles for containers${NC}"
    ((recommendations++))
fi

if [ "$recommendations" -eq 0 ]; then
    echo -e "${GREEN}✓ Excellent security posture!${NC}"
fi

echo ""
echo "9. Compliance Score"
echo "-----------------"

# Calculate compliance score
score=100

# Deduct points for security issues
[ "$privileged_pods" -gt 0 ] && score=$((score - 20))
[ "$host_pid_pods" -gt 0 ] && score=$((score - 15))
[ "$host_network_pods" -gt 0 ] && score=$((score - 10))
[ "$root_pods" -gt $((total_pods / 4)) ] && score=$((score - 10))
[ "$no_security_context_pods" -gt $((total_pods / 3)) ] && score=$((score - 10))
[ "$default_sa_pods" -gt $((total_pods / 2)) ] && score=$((score - 5))
[ "$no_resource_limits_pods" -gt $((total_pods / 3)) ] && score=$((score - 5))
[ "$netpol_count" -eq 0 ] && score=$((score - 10))
[ "$pss_namespaces" -eq 0 ] && score=$((score - 5))
[ "$latest_image_pods" -gt 0 ] && score=$((score - 5))

# Ensure score doesn't go below 0
[ "$score" -lt 0 ] && score=0

# Color code the score
if [ "$score" -ge 90 ]; then
    score_color="$GREEN"
elif [ "$score" -ge 70 ]; then
    score_color="$YELLOW"
else
    score_color="$RED"
fi

echo -e "Security Compliance Score: ${score_color}${score}/100${NC}"
echo ""
echo "Score Breakdown:"
echo "  Base score: 100"
[ "$privileged_pods" -gt 0 ] && echo "  Privileged pods: -20"
[ "$host_pid_pods" -gt 0 ] && echo "  Host PID usage: -15"
[ "$host_network_pods" -gt 0 ] && echo "  Host network usage: -10"
[ "$root_pods" -gt $((total_pods / 4)) ] && echo "  Excessive root usage: -10"
[ "$no_security_context_pods" -gt $((total_pods / 3)) ] && echo "  Missing security context: -10"
[ "$netpol_count" -eq 0 ] && echo "  No network policies: -10"

echo ""
echo "======================================"
echo "Pod Security Check Complete"
echo ""
echo "Summary:"
echo "- Total pods analyzed: $total_pods"
echo "- Security score: ${score}/100"
echo "- Critical issues: $((privileged_pods + host_pid_pods))"
echo "- Recommendations: $recommendations"
echo "======================================"
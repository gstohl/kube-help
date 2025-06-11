#!/bin/bash

# Network Connectivity Test Script
# This script performs comprehensive network connectivity tests in Kubernetes

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test configuration
TEST_NAMESPACE="network-test-$$"
TEST_IMAGE="nicolaka/netshoot:latest"
CLEANUP_ON_EXIT=true

echo "======================================"
echo "Kubernetes Network Connectivity Test"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

# Cleanup function
cleanup() {
    if [ "$CLEANUP_ON_EXIT" = true ]; then
        echo ""
        echo "Cleaning up test resources..."
        kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found=true &> /dev/null || true
    fi
}

# Set trap for cleanup
trap cleanup EXIT

echo "1. Cluster Network Overview"
echo "-------------------------"

# Get cluster CIDR information
echo "Network Configuration:"

# Try to get pod network CIDR
pod_cidr=""
service_cidr=""

# Check various sources for network configuration
# From kubeadm
if kubectl get configmap -n kube-system kubeadm-config -o yaml 2>/dev/null | grep -q podSubnet; then
    pod_cidr=$(kubectl get configmap -n kube-system kubeadm-config -o yaml | grep podSubnet | awk '{print $2}')
    echo "  Pod Network CIDR: $pod_cidr (from kubeadm-config)"
fi

# From kube-proxy
if [ -z "$pod_cidr" ]; then
    kube_proxy_cm=$(kubectl get configmap -n kube-system kube-proxy -o yaml 2>/dev/null | grep clusterCIDR || true)
    if [ -n "$kube_proxy_cm" ]; then
        pod_cidr=$(echo "$kube_proxy_cm" | awk '{print $2}' | tr -d '"')
        echo "  Pod Network CIDR: $pod_cidr (from kube-proxy)"
    fi
fi

# Service CIDR from API server
api_server_pod=$(kubectl get pods -n kube-system -l component=kube-apiserver -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$api_server_pod" ]; then
    service_cidr=$(kubectl get pod -n kube-system "$api_server_pod" -o yaml | grep service-cluster-ip-range | awk -F= '{print $2}' | tr -d ' ' || true)
    [ -n "$service_cidr" ] && echo "  Service CIDR: $service_cidr"
fi

# Detect CNI plugin
echo ""
echo "CNI Plugin Detection:"
for cni in "calico" "weave" "flannel" "cilium" "canal" "kube-router" "antrea" "multus"; do
    if kubectl get pods --all-namespaces 2>/dev/null | grep -qi "$cni"; then
        echo -e "  ${GREEN}✓ Found $cni CNI${NC}"
        
        # Get CNI pod status
        cni_pods=$(kubectl get pods --all-namespaces -o wide 2>/dev/null | grep -i "$cni" | grep -v "Completed" | wc -l)
        cni_running=$(kubectl get pods --all-namespaces -o wide 2>/dev/null | grep -i "$cni" | grep "Running" | wc -l)
        echo "    Pods: $cni_running/$cni_pods running"
    fi
done

echo ""
echo "2. DNS Service Check"
echo "------------------"

# Check kube-dns service
dns_service=$(kubectl get service -n kube-system kube-dns -o json 2>/dev/null)
if [ -n "$dns_service" ]; then
    dns_ip=$(echo "$dns_service" | jq -r '.spec.clusterIP')
    echo -e "${GREEN}✓ DNS Service found${NC}"
    echo "  Cluster DNS IP: $dns_ip"
    
    # Check DNS endpoints
    dns_endpoints=$(kubectl get endpoints -n kube-system kube-dns -o json | jq '.subsets[0].addresses | length' 2>/dev/null || echo "0")
    echo "  DNS Endpoints: $dns_endpoints"
    
    if [ "$dns_endpoints" -eq 0 ]; then
        echo -e "  ${RED}✗ No DNS endpoints available${NC}"
    fi
else
    echo -e "${RED}✗ DNS Service not found${NC}"
fi

echo ""
echo "3. Service Connectivity Matrix"
echo "----------------------------"

# Get all services and check their endpoints
echo "Checking service endpoints..."

namespaces=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')
services_without_endpoints=0
total_services=0

for ns in $namespaces; do
    services=$(kubectl get services -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    for svc in $services; do
        ((total_services++))
        
        # Skip kubernetes service in default namespace
        if [ "$ns" = "default" ] && [ "$svc" = "kubernetes" ]; then
            continue
        fi
        
        # Check if service has endpoints
        endpoint_count=$(kubectl get endpoints -n "$ns" "$svc" -o json 2>/dev/null | jq '.subsets[0].addresses | length' 2>/dev/null || echo "0")
        
        if [ "$endpoint_count" -eq 0 ]; then
            # Check if it's a headless service or ExternalName
            svc_type=$(kubectl get service -n "$ns" "$svc" -o jsonpath='{.spec.type}' 2>/dev/null)
            cluster_ip=$(kubectl get service -n "$ns" "$svc" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
            
            if [ "$svc_type" != "ExternalName" ] && [ "$cluster_ip" != "None" ]; then
                ((services_without_endpoints++))
                [ "$services_without_endpoints" -le 10 ] && echo -e "  ${YELLOW}⚠ $ns/$svc has no endpoints${NC}"
            fi
        fi
    done
done

echo ""
echo "Service Summary:"
echo "  Total services: $total_services"
echo "  Services without endpoints: $services_without_endpoints"

if [ "$services_without_endpoints" -gt 10 ]; then
    echo -e "  ${YELLOW}(Showing first 10, $((services_without_endpoints - 10)) more...)${NC}"
fi

echo ""
echo "4. Creating Network Test Environment"
echo "----------------------------------"

# Create test namespace
echo "Creating test namespace: $TEST_NAMESPACE"
kubectl create namespace "$TEST_NAMESPACE" &> /dev/null

# Create test pods on different nodes if possible
nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
node_array=($nodes)
node_count=${#node_array[@]}

echo "Available nodes: $node_count"

# Create server pod
echo ""
echo "Creating test server pod..."
cat <<EOF | kubectl apply -f - &> /dev/null
apiVersion: v1
kind: Pod
metadata:
  name: nettest-server
  namespace: $TEST_NAMESPACE
  labels:
    app: nettest-server
spec:
  containers:
  - name: netshoot
    image: $TEST_IMAGE
    command: ["/bin/sh"]
    args: ["-c", "while true; do nc -l -p 8080 -e echo 'HTTP/1.1 200 OK\n\nServer Response'; done"]
  - name: nginx
    image: nginx:alpine
    ports:
    - containerPort: 80
  restartPolicy: Never
  ${node_count:+nodeSelector:}
    ${node_count:+kubernetes.io/hostname: ${node_array[0]}}
EOF

# Create server service
cat <<EOF | kubectl apply -f - &> /dev/null
apiVersion: v1
kind: Service
metadata:
  name: nettest-service
  namespace: $TEST_NAMESPACE
spec:
  selector:
    app: nettest-server
  ports:
  - name: http
    port: 80
    targetPort: 80
  - name: test
    port: 8080
    targetPort: 8080
EOF

# Create client pod (try to schedule on different node)
echo "Creating test client pod..."
client_node="${node_array[0]}"
if [ "$node_count" -gt 1 ]; then
    client_node="${node_array[1]}"
fi

cat <<EOF | kubectl apply -f - &> /dev/null
apiVersion: v1
kind: Pod
metadata:
  name: nettest-client
  namespace: $TEST_NAMESPACE
  labels:
    app: nettest-client
spec:
  containers:
  - name: netshoot
    image: $TEST_IMAGE
    command: ["sleep", "3600"]
  restartPolicy: Never
  ${node_count:+nodeSelector:}
    ${node_count:+kubernetes.io/hostname: $client_node}
EOF

# Wait for pods to be ready
echo ""
echo "Waiting for test pods to be ready..."
kubectl wait --for=condition=Ready pod/nettest-server -n "$TEST_NAMESPACE" --timeout=60s &> /dev/null || echo -e "${YELLOW}⚠ Server pod not ready${NC}"
kubectl wait --for=condition=Ready pod/nettest-client -n "$TEST_NAMESPACE" --timeout=60s &> /dev/null || echo -e "${YELLOW}⚠ Client pod not ready${NC}"

echo ""
echo "5. Pod-to-Pod Connectivity Tests"
echo "-------------------------------"

# Get pod IPs
server_ip=$(kubectl get pod nettest-server -n "$TEST_NAMESPACE" -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
client_ip=$(kubectl get pod nettest-client -n "$TEST_NAMESPACE" -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")

if [ -n "$server_ip" ] && [ -n "$client_ip" ]; then
    echo "Test pod IPs:"
    echo "  Server: $server_ip"
    echo "  Client: $client_ip"
    
    # Test direct pod-to-pod connectivity
    echo ""
    echo -n "Pod-to-Pod connectivity (HTTP): "
    if kubectl exec nettest-client -n "$TEST_NAMESPACE" -- curl -s --connect-timeout 5 "http://$server_ip" &> /dev/null; then
        echo -e "${GREEN}✓ Success${NC}"
    else
        echo -e "${RED}✗ Failed${NC}"
    fi
    
    # Test ping if available
    echo -n "Pod-to-Pod connectivity (ICMP): "
    if kubectl exec nettest-client -n "$TEST_NAMESPACE" -- ping -c 1 -W 2 "$server_ip" &> /dev/null; then
        echo -e "${GREEN}✓ Success${NC}"
    else
        echo -e "${YELLOW}⚠ Failed (may be blocked by network policy)${NC}"
    fi
else
    echo -e "${RED}✗ Could not get pod IPs${NC}"
fi

echo ""
echo "6. Service Connectivity Tests"
echo "---------------------------"

# Test service connectivity
service_ip=$(kubectl get service nettest-service -n "$TEST_NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")

if [ -n "$service_ip" ]; then
    echo "Service ClusterIP: $service_ip"
    
    echo ""
    echo -n "Service connectivity (ClusterIP): "
    if kubectl exec nettest-client -n "$TEST_NAMESPACE" -- curl -s --connect-timeout 5 "http://$service_ip" &> /dev/null; then
        echo -e "${GREEN}✓ Success${NC}"
    else
        echo -e "${RED}✗ Failed${NC}"
    fi
    
    # Test service DNS
    echo -n "Service DNS resolution: "
    if kubectl exec nettest-client -n "$TEST_NAMESPACE" -- nslookup nettest-service.$TEST_NAMESPACE.svc.cluster.local &> /dev/null; then
        echo -e "${GREEN}✓ Success${NC}"
    else
        echo -e "${RED}✗ Failed${NC}"
    fi
    
    echo -n "Service connectivity (DNS): "
    if kubectl exec nettest-client -n "$TEST_NAMESPACE" -- curl -s --connect-timeout 5 "http://nettest-service.$TEST_NAMESPACE.svc.cluster.local" &> /dev/null; then
        echo -e "${GREEN}✓ Success${NC}"
    else
        echo -e "${RED}✗ Failed${NC}"
    fi
fi

echo ""
echo "7. DNS Resolution Tests"
echo "---------------------"

echo "Testing DNS resolution from pod..."

# Test internal DNS
dns_tests=(
    "kubernetes.default.svc.cluster.local:Kubernetes API"
    "kube-dns.kube-system.svc.cluster.local:CoreDNS Service"
    "google.com:External DNS"
)

for test in "${dns_tests[@]}"; do
    host=$(echo "$test" | cut -d: -f1)
    desc=$(echo "$test" | cut -d: -f2)
    
    echo -n "  $desc ($host): "
    if kubectl exec nettest-client -n "$TEST_NAMESPACE" -- nslookup "$host" &> /dev/null; then
        echo -e "${GREEN}✓ Resolved${NC}"
    else
        echo -e "${RED}✗ Failed${NC}"
    fi
done

echo ""
echo "8. External Connectivity Test"
echo "---------------------------"

echo -n "Internet connectivity (HTTP): "
if kubectl exec nettest-client -n "$TEST_NAMESPACE" -- curl -s --connect-timeout 5 http://www.google.com &> /dev/null; then
    echo -e "${GREEN}✓ Success${NC}"
else
    echo -e "${RED}✗ Failed${NC}"
fi

echo -n "Internet connectivity (HTTPS): "
if kubectl exec nettest-client -n "$TEST_NAMESPACE" -- curl -s --connect-timeout 5 https://www.google.com &> /dev/null; then
    echo -e "${GREEN}✓ Success${NC}"
else
    echo -e "${RED}✗ Failed${NC}"
fi

echo ""
echo "9. Network Policy Impact Test"
echo "---------------------------"

# Check if network policies exist
netpol_count=$(kubectl get networkpolicies --all-namespaces 2>/dev/null | grep -v "NAMESPACE" | wc -l)

if [ "$netpol_count" -gt 0 ]; then
    echo "Network policies detected: $netpol_count"
    
    # Check if test namespace has policies
    test_netpol=$(kubectl get networkpolicies -n "$TEST_NAMESPACE" 2>/dev/null | grep -v "NAME" | wc -l)
    
    if [ "$test_netpol" -gt 0 ]; then
        echo -e "${YELLOW}⚠ Network policies active in test namespace${NC}"
    else
        echo -e "${GREEN}✓ No network policies in test namespace${NC}"
    fi
    
    # Test with a deny-all policy
    echo ""
    echo "Testing with deny-all network policy..."
    
    cat <<EOF | kubectl apply -f - &> /dev/null
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: $TEST_NAMESPACE
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF
    
    sleep 2
    
    echo -n "Pod connectivity with deny-all policy: "
    if kubectl exec nettest-client -n "$TEST_NAMESPACE" -- curl -s --connect-timeout 3 "http://$server_ip" &> /dev/null; then
        echo -e "${YELLOW}⚠ Still working (CNI may not enforce policies)${NC}"
    else
        echo -e "${GREEN}✓ Blocked as expected${NC}"
    fi
    
    # Clean up the policy
    kubectl delete networkpolicy deny-all -n "$TEST_NAMESPACE" &> /dev/null
else
    echo "No network policies configured in cluster"
fi

echo ""
echo "10. MTU and Fragmentation Test"
echo "----------------------------"

echo "Testing MTU sizes..."

# Get interface MTU from pod
mtu=$(kubectl exec nettest-client -n "$TEST_NAMESPACE" -- ip link show eth0 2>/dev/null | grep mtu | awk '{print $5}' || echo "unknown")
echo "Pod interface MTU: $mtu"

if [ -n "$server_ip" ]; then
    # Test with different packet sizes
    for size in 1000 1400 1500 9000; do
        echo -n "  Ping with $size bytes: "
        if kubectl exec nettest-client -n "$TEST_NAMESPACE" -- ping -c 1 -W 2 -s "$size" "$server_ip" &> /dev/null; then
            echo -e "${GREEN}✓ Success${NC}"
        else
            if [ "$size" -gt "${mtu:-1500}" ]; then
                echo -e "${YELLOW}⚠ Failed (larger than MTU)${NC}"
            else
                echo -e "${RED}✗ Failed${NC}"
            fi
        fi
    done
fi

echo ""
echo "11. Load Balancer and Ingress Test"
echo "---------------------------------"

# Check for LoadBalancer services
lb_services=$(kubectl get services --all-namespaces -o json | jq '[.items[] | select(.spec.type == "LoadBalancer")] | length')
echo "LoadBalancer services: $lb_services"

if [ "$lb_services" -gt 0 ]; then
    echo "LoadBalancer IPs:"
    kubectl get services --all-namespaces -o json | jq -r '.items[] | select(.spec.type == "LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name): \(.status.loadBalancer.ingress[0].ip // .status.loadBalancer.ingress[0].hostname // "pending")"' | head -5
fi

# Check for Ingress resources
ingress_count=$(kubectl get ingress --all-namespaces 2>/dev/null | grep -v "NAMESPACE" | wc -l)
echo ""
echo "Ingress resources: $ingress_count"

if [ "$ingress_count" -gt 0 ]; then
    echo "Ingress controllers:"
    kubectl get pods --all-namespaces | grep -E "ingress|nginx-controller|traefik|haproxy-controller|istio-gateway" | awk '{print $1"/"$2": "$4}' | head -5
fi

echo ""
echo "12. Network Performance Indicators"
echo "--------------------------------"

# Check for network-related events
echo "Recent network-related events:"

network_events=$(kubectl get events --all-namespaces --field-selector type=Warning -o json | jq '.items[] | select(.message | test("network|Network|connection|timeout|DNS"))')
event_count=$(echo "$network_events" | jq -s 'length')

if [ "$event_count" -gt 0 ]; then
    echo -e "${YELLOW}Found $event_count network-related warning events${NC}"
    echo "$network_events" | jq -s -r '.[-5:] | .[] | "\(.lastTimestamp): \(.reason) - \(.message)"'
else
    echo -e "${GREEN}✓ No recent network warning events${NC}"
fi

echo ""
echo "13. Network Recommendations"
echo "-------------------------"

recommendations=0

# DNS issues
if [ "${dns_endpoints:-0}" -eq 0 ]; then
    echo -e "${RED}• CRITICAL: DNS service has no endpoints${NC}"
    ((recommendations++))
fi

# Service endpoint issues
if [ "${services_without_endpoints:-0}" -gt 10 ]; then
    echo -e "${YELLOW}• HIGH: $services_without_endpoints services have no endpoints${NC}"
    ((recommendations++))
fi

# Network policy recommendations
if [ "$netpol_count" -eq 0 ]; then
    echo -e "${BLUE}• Consider implementing network policies for security${NC}"
    ((recommendations++))
fi

# MTU recommendations
if [ "${mtu:-1500}" -lt 1500 ]; then
    echo -e "${YELLOW}• MTU is less than 1500, may impact performance${NC}"
    ((recommendations++))
fi

# LoadBalancer recommendations
if [ "$lb_services" -gt 0 ] && ! kubectl get services --all-namespaces -o json | jq -e '.items[] | select(.spec.type == "LoadBalancer" and .status.loadBalancer.ingress != null)' &> /dev/null; then
    echo -e "${YELLOW}• Some LoadBalancer services are pending external IPs${NC}"
    ((recommendations++))
fi

if [ "$recommendations" -eq 0 ]; then
    echo -e "${GREEN}✓ Network configuration looks healthy!${NC}"
fi

echo ""
echo "======================================"
echo "Network Connectivity Test Complete"
echo ""
echo "Summary:"
echo "- CNI Plugin: Detected"
echo "- DNS Service: $([ "${dns_endpoints:-0}" -gt 0 ] && echo "Healthy" || echo "Issues detected")"
echo "- Pod-to-Pod: $([ -n "$server_ip" ] && echo "Tested" || echo "Not tested")"
echo "- External connectivity: Tested"
echo "- Network policies: $netpol_count configured"
[ "$recommendations" -gt 0 ] && echo -e "- ${YELLOW}Recommendations: $recommendations${NC}"
echo "======================================"

# Cleanup handled by trap
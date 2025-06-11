#!/bin/bash

# cert-manager Health Check Script
# This script checks the health status of cert-manager and certificate resources

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
CERT_WARNING_DAYS=30
CERT_CRITICAL_DAYS=7

echo "======================================"
echo "cert-manager Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

# Check if cert-manager is installed
NAMESPACE="cert-manager"
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo -e "${RED}Error: cert-manager namespace not found${NC}"
    echo "To install cert-manager:"
    echo "kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml"
    exit 1
fi

echo -e "${BLUE}Found cert-manager in namespace: $NAMESPACE${NC}"
echo ""

echo "1. cert-manager Deployment Status..."
echo "----------------------------------"

# Check deployments
deployments=("cert-manager" "cert-manager-webhook" "cert-manager-cainjector")
all_healthy=true

for deployment in "${deployments[@]}"; do
    echo -n "Checking $deployment: "
    
    dep_info=$(kubectl get deployment -n "$NAMESPACE" "$deployment" -o json 2>/dev/null)
    if [ -z "$dep_info" ] || [ "$dep_info" = "null" ]; then
        echo -e "${RED}✗ Not found${NC}"
        all_healthy=false
        continue
    fi
    
    replicas=$(echo "$dep_info" | jq '.spec.replicas')
    ready_replicas=$(echo "$dep_info" | jq '.status.readyReplicas // 0')
    
    if [ "$ready_replicas" -eq "$replicas" ]; then
        echo -e "${GREEN}✓ $ready_replicas/$replicas replicas ready${NC}"
    else
        echo -e "${YELLOW}⚠ $ready_replicas/$replicas replicas ready${NC}"
        all_healthy=false
    fi
    
    # Check for recent restarts
    pod_selector="app.kubernetes.io/name=$deployment"
    if [ "$deployment" = "cert-manager" ]; then
        pod_selector="app=cert-manager"
    fi
    
    high_restarts=$(kubectl get pods -n "$NAMESPACE" -l "$pod_selector" -o json | jq '[.items[] | select(.status.containerStatuses[]?.restartCount > 5)] | length')
    if [ "$high_restarts" -gt 0 ]; then
        echo -e "  ${YELLOW}⚠ $high_restarts pod(s) with high restart count${NC}"
    fi
done

echo ""
echo "2. cert-manager Pod Health..."
echo "---------------------------"

# Get all cert-manager pods
cm_pods=$(kubectl get pods -n "$NAMESPACE" -o json)
total_pods=$(echo "$cm_pods" | jq '.items | length')
running_pods=$(echo "$cm_pods" | jq '[.items[] | select(.status.phase == "Running")] | length')

echo "Total cert-manager pods: $total_pods"
if [ "$running_pods" -eq "$total_pods" ]; then
    echo -e "${GREEN}✓ All pods running: $running_pods/$total_pods${NC}"
else
    echo -e "${YELLOW}⚠ Only $running_pods/$total_pods pods running${NC}"
    
    # Show problematic pods
    echo ""
    echo "Non-running pods:"
    kubectl get pods -n "$NAMESPACE" --field-selector='status.phase!=Running' 2>/dev/null || echo "  None found"
fi

echo ""
echo "3. cert-manager CRDs..."
echo "---------------------"

# Check CRDs
crds=("certificates.cert-manager.io" "issuers.cert-manager.io" "clusterissuers.cert-manager.io" 
      "certificaterequests.cert-manager.io" "orders.acme.cert-manager.io" "challenges.acme.cert-manager.io")

echo "Checking Custom Resource Definitions:"
missing_crds=0
for crd in "${crds[@]}"; do
    if kubectl get crd "$crd" &> /dev/null; then
        version=$(kubectl get crd "$crd" -o jsonpath='{.spec.versions[0].name}')
        echo -e "  ${GREEN}✓ $crd (version: $version)${NC}"
    else
        echo -e "  ${RED}✗ $crd not found${NC}"
        ((missing_crds++))
    fi
done

if [ "$missing_crds" -gt 0 ]; then
    echo -e "${RED}✗ Missing $missing_crds CRDs - cert-manager may not function properly${NC}"
fi

echo ""
echo "4. Webhook Configuration..."
echo "-------------------------"

# Check webhook
webhook=$(kubectl get validatingwebhookconfiguration cert-manager-webhook -o json 2>/dev/null)
if [ -n "$webhook" ] && [ "$webhook" != "null" ]; then
    echo -e "${GREEN}✓ Validating webhook configured${NC}"
    
    # Check webhook endpoints
    webhook_endpoints=$(echo "$webhook" | jq '.webhooks | length')
    echo "  Webhook endpoints: $webhook_endpoints"
    
    # Check CA bundle
    ca_bundle=$(echo "$webhook" | jq -r '.webhooks[0].clientConfig.caBundle' | wc -c)
    if [ "$ca_bundle" -gt 100 ]; then
        echo -e "  ${GREEN}✓ CA bundle configured${NC}"
    else
        echo -e "  ${YELLOW}⚠ CA bundle may not be properly injected${NC}"
    fi
else
    echo -e "${RED}✗ Webhook not found${NC}"
fi

# Check mutating webhook
mutating_webhook=$(kubectl get mutatingwebhookconfiguration cert-manager-webhook -o json 2>/dev/null)
if [ -n "$mutating_webhook" ] && [ "$mutating_webhook" != "null" ]; then
    echo -e "${GREEN}✓ Mutating webhook configured${NC}"
else
    echo -e "${YELLOW}⚠ Mutating webhook not found${NC}"
fi

echo ""
echo "5. Issuers and ClusterIssuers..."
echo "------------------------------"

# Check Issuers
issuers=$(kubectl get issuers --all-namespaces -o json)
issuer_count=$(echo "$issuers" | jq '.items | length')
ready_issuers=$(echo "$issuers" | jq '[.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "True"))] | length')

echo "Issuers:"
echo "  Total: $issuer_count"
echo "  Ready: $ready_issuers"

if [ "$issuer_count" -gt 0 ] && [ "$ready_issuers" -lt "$issuer_count" ]; then
    not_ready=$((issuer_count - ready_issuers))
    echo -e "  ${YELLOW}⚠ Not ready: $not_ready${NC}"
    
    # Show not ready issuers
    echo ""
    echo "Not ready Issuers:"
    echo "$issuers" | jq -r '.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status != "True")) | "\(.metadata.namespace)/\(.metadata.name): \(.status.conditions[] | select(.type == "Ready") | .message)"' | head -5
fi

# Check ClusterIssuers
cluster_issuers=$(kubectl get clusterissuers -o json)
cluster_issuer_count=$(echo "$cluster_issuers" | jq '.items | length')
ready_cluster_issuers=$(echo "$cluster_issuers" | jq '[.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "True"))] | length')

echo ""
echo "ClusterIssuers:"
echo "  Total: $cluster_issuer_count"
echo "  Ready: $ready_cluster_issuers"

if [ "$cluster_issuer_count" -gt 0 ] && [ "$ready_cluster_issuers" -lt "$cluster_issuer_count" ]; then
    not_ready=$((cluster_issuer_count - ready_cluster_issuers))
    echo -e "  ${YELLOW}⚠ Not ready: $not_ready${NC}"
fi

# Show issuer types
echo ""
echo "Issuer types in use:"
all_issuers=$(kubectl get issuers,clusterissuers --all-namespaces -o json)
issuer_types=$(echo "$all_issuers" | jq -r '.items[].spec | keys[] | select(. != "acme" and . != "ca" and . != "vault" and . != "venafi" and . != "selfSigned") | .' | sort | uniq -c)

# Check for each known type
for type in "acme" "ca" "vault" "venafi" "selfSigned"; do
    count=$(echo "$all_issuers" | jq "[.items[] | select(.spec.$type != null)] | length")
    [ "$count" -gt 0 ] && echo "  $type: $count"
done

echo ""
echo "6. Certificate Status..."
echo "----------------------"

# Get all certificates
certificates=$(kubectl get certificates --all-namespaces -o json)
total_certs=$(echo "$certificates" | jq '.items | length')

if [ "$total_certs" -eq 0 ]; then
    echo "No certificates found"
else
    echo "Total certificates: $total_certs"
    
    # Certificate status breakdown
    ready_certs=$(echo "$certificates" | jq '[.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "True"))] | length')
    not_ready_certs=$((total_certs - ready_certs))
    
    echo -e "  ${GREEN}✓ Ready: $ready_certs${NC}"
    [ "$not_ready_certs" -gt 0 ] && echo -e "  ${YELLOW}⚠ Not ready: $not_ready_certs${NC}"
    
    # Check for specific issues
    issuing_certs=$(echo "$certificates" | jq '[.items[] | select(.status.conditions[]? | select(.type == "Issuing" and .status == "True"))] | length')
    [ "$issuing_certs" -gt 0 ] && echo -e "  ${BLUE}ℹ Currently issuing: $issuing_certs${NC}"
    
    # Show failed certificates
    failed_certs=$(echo "$certificates" | jq -r '.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "False")) | "\(.metadata.namespace)/\(.metadata.name): \(.status.conditions[] | select(.type == "Ready") | .reason) - \(.status.conditions[] | select(.type == "Ready") | .message)"' | head -5)
    if [ -n "$failed_certs" ]; then
        echo ""
        echo "Failed certificates:"
        echo "$failed_certs"
    fi
fi

echo ""
echo "7. Certificate Expiration Check..."
echo "--------------------------------"

if [ "$total_certs" -gt 0 ]; then
    current_time=$(date +%s)
    warning_time=$((current_time + CERT_WARNING_DAYS * 24 * 60 * 60))
    critical_time=$((current_time + CERT_CRITICAL_DAYS * 24 * 60 * 60))
    
    expired_count=0
    critical_count=0
    warning_count=0
    
    echo "Checking certificate expiration dates..."
    
    for i in $(seq 0 $((total_certs - 1))); do
        cert=$(echo "$certificates" | jq ".items[$i]")
        cert_name=$(echo "$cert" | jq -r '"\(.metadata.namespace)/\(.metadata.name)"')
        
        # Get renewal time
        renewal_time=$(echo "$cert" | jq -r '.status.renewalTime // empty')
        not_after=$(echo "$cert" | jq -r '.status.notAfter // empty')
        
        if [ -n "$not_after" ]; then
            # Convert to epoch
            if [[ "$OSTYPE" == "darwin"* ]]; then
                expiry_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$not_after" +%s 2>/dev/null || echo "0")
            else
                expiry_epoch=$(date -d "$not_after" +%s 2>/dev/null || echo "0")
            fi
            
            if [ "$expiry_epoch" -lt "$current_time" ]; then
                echo -e "  ${RED}✗ EXPIRED: $cert_name${NC}"
                ((expired_count++))
            elif [ "$expiry_epoch" -lt "$critical_time" ]; then
                days_left=$(( (expiry_epoch - current_time) / 86400 ))
                echo -e "  ${RED}⚠ CRITICAL: $cert_name (expires in $days_left days)${NC}"
                ((critical_count++))
            elif [ "$expiry_epoch" -lt "$warning_time" ]; then
                days_left=$(( (expiry_epoch - current_time) / 86400 ))
                echo -e "  ${YELLOW}⚠ WARNING: $cert_name (expires in $days_left days)${NC}"
                ((warning_count++))
            fi
        fi
    done
    
    # Summary
    echo ""
    echo "Expiration Summary:"
    echo -e "  ${RED}Expired: $expired_count${NC}"
    echo -e "  ${RED}Critical (<$CERT_CRITICAL_DAYS days): $critical_count${NC}"
    echo -e "  ${YELLOW}Warning (<$CERT_WARNING_DAYS days): $warning_count${NC}"
    
    healthy_certs=$((total_certs - expired_count - critical_count - warning_count))
    echo -e "  ${GREEN}Healthy: $healthy_certs${NC}"
fi

echo ""
echo "8. ACME Orders and Challenges..."
echo "------------------------------"

# Check Orders
orders=$(kubectl get orders --all-namespaces -o json)
order_count=$(echo "$orders" | jq '.items | length')

if [ "$order_count" -gt 0 ]; then
    echo "ACME Orders: $order_count"
    
    # Order states
    for state in "pending" "ready" "processing" "valid" "invalid"; do
        count=$(echo "$orders" | jq "[.items[] | select(.status.state == \"$state\")] | length")
        [ "$count" -gt 0 ] && echo "  $state: $count"
    done
    
    # Failed orders
    failed_orders=$(echo "$orders" | jq '[.items[] | select(.status.state == "invalid")] | length')
    if [ "$failed_orders" -gt 0 ]; then
        echo ""
        echo "Failed orders:"
        echo "$orders" | jq -r '.items[] | select(.status.state == "invalid") | "\(.metadata.namespace)/\(.metadata.name): \(.status.failureTime)"' | head -5
    fi
else
    echo "No ACME orders found"
fi

# Check Challenges
echo ""
challenges=$(kubectl get challenges --all-namespaces -o json)
challenge_count=$(echo "$challenges" | jq '.items | length')

if [ "$challenge_count" -gt 0 ]; then
    echo "ACME Challenges: $challenge_count"
    
    # Challenge states
    pending_challenges=$(echo "$challenges" | jq '[.items[] | select(.status.state == "pending")] | length')
    processing_challenges=$(echo "$challenges" | jq '[.items[] | select(.status.state == "processing")] | length')
    
    [ "$pending_challenges" -gt 0 ] && echo -e "  ${YELLOW}Pending: $pending_challenges${NC}"
    [ "$processing_challenges" -gt 0 ] && echo -e "  ${BLUE}Processing: $processing_challenges${NC}"
    
    # Check for stuck challenges
    if [ "$pending_challenges" -gt 0 ] || [ "$processing_challenges" -gt 0 ]; then
        echo ""
        echo "Active challenges:"
        echo "$challenges" | jq -r '.items[] | select(.status.state == "pending" or .status.state == "processing") | "\(.metadata.namespace)/\(.metadata.name): \(.spec.type) - \(.status.state)"' | head -5
    fi
fi

echo ""
echo "9. cert-manager Logs Analysis..."
echo "------------------------------"

# Check for errors in cert-manager controller
controller_pod=$(kubectl get pods -n "$NAMESPACE" -l app=cert-manager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$controller_pod" ]; then
    echo "Analyzing cert-manager controller logs..."
    
    error_count=$(kubectl logs -n "$NAMESPACE" "$controller_pod" --tail=500 2>/dev/null | grep -ciE "error|failed" || echo "0")
    
    if [ "$error_count" -gt 0 ]; then
        echo -e "${YELLOW}⚠ Found $error_count error messages in recent logs${NC}"
        
        # Show sample errors
        echo ""
        echo "Recent errors:"
        kubectl logs -n "$NAMESPACE" "$controller_pod" --tail=500 2>/dev/null | grep -iE "error|failed" | tail -5
    else
        echo -e "${GREEN}✓ No errors in recent logs${NC}"
    fi
    
    # Check for specific issues
    rate_limit=$(kubectl logs -n "$NAMESPACE" "$controller_pod" --tail=500 2>/dev/null | grep -c "too many certificates" || echo "0")
    if [ "$rate_limit" -gt 0 ]; then
        echo -e "${RED}✗ Rate limiting detected - too many certificate requests${NC}"
    fi
fi

echo ""
echo "10. Integration Status..."
echo "-----------------------"

# Check for common integrations
echo "Checking integrations:"

# Check if metrics are exposed
metrics_svc=$(kubectl get service -n "$NAMESPACE" cert-manager -o jsonpath='{.spec.ports[?(@.name=="tcp-prometheus-servicemonitor")].port}' 2>/dev/null)
if [ -n "$metrics_svc" ]; then
    echo -e "  ${GREEN}✓ Prometheus metrics exposed on port $metrics_svc${NC}"
else
    echo -e "  ${YELLOW}ℹ Prometheus metrics not configured${NC}"
fi

# Check for ServiceMonitor (Prometheus Operator)
if kubectl get crd servicemonitors.monitoring.coreos.com &> /dev/null; then
    sm_count=$(kubectl get servicemonitor -n "$NAMESPACE" -o json | jq '.items | length')
    if [ "$sm_count" -gt 0 ]; then
        echo -e "  ${GREEN}✓ ServiceMonitor configured for Prometheus Operator${NC}"
    fi
fi

# Check common DNS providers for ACME
echo ""
echo "DNS01 solver configurations:"
dns_solvers=$(echo "$all_issuers" | jq -r '.items[].spec.acme.solvers[]?.dns01 | keys[]' 2>/dev/null | sort | uniq -c)
if [ -n "$dns_solvers" ]; then
    echo "$dns_solvers" | sed 's/^/  /'
else
    echo "  No DNS01 solvers configured"
fi

echo ""
echo "======================================"
echo "cert-manager Health Check Complete"
echo ""
echo "Summary:"
echo "- Deployments: $([ "$all_healthy" = true ] && echo "All healthy" || echo "Some issues detected")"
echo "- Certificates: $total_certs total, $ready_certs ready"
echo "- Issuers: $issuer_count Issuers, $cluster_issuer_count ClusterIssuers"
[ "$expired_count" -gt 0 ] && echo -e "- ${RED}Expired certificates: $expired_count${NC}"
[ "$critical_count" -gt 0 ] && echo -e "- ${RED}Critical expirations: $critical_count${NC}"
echo "======================================="
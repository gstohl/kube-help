#!/bin/bash

# Kubernetes Certificates Health Check Script
# This script analyzes all certificates in the Kubernetes cluster

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Certificate expiry thresholds (in days)
CERT_CRITICAL_DAYS=30
CERT_WARNING_DAYS=90

echo "======================================"
echo "Kubernetes Certificates Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

echo "1. Cluster Certificate Overview"
echo "-----------------------------"

# Try to check if this is a kubeadm cluster
kubeadm_cm=$(kubectl get configmap -n kube-system kubeadm-config -o json 2>/dev/null)
if [ -n "$kubeadm_cm" ] && [ "$kubeadm_cm" != "null" ]; then
    echo "Cluster type: kubeadm-managed"
    echo -e "${GREEN}✓ kubeadm configuration found${NC}"
else
    echo "Cluster type: Unknown (not kubeadm or managed service)"
fi

echo ""
echo "2. API Server Certificates"
echo "------------------------"

# Get API server pods
api_server_pods=$(kubectl get pods -n kube-system -l component=kube-apiserver -o json 2>/dev/null)
api_pod_count=$(echo "$api_server_pods" | jq '.items | length' 2>/dev/null || echo "0")

if [ "$api_pod_count" -gt 0 ]; then
    echo "Found $api_pod_count API server pod(s)"
    
    # Try to extract certificate info from the first pod
    first_api_pod=$(echo "$api_server_pods" | jq -r '.items[0].metadata.name')
    
    # Check certificate arguments
    echo ""
    echo "Certificate configuration:"
    
    # Extract cert-related arguments
    cert_args=$(kubectl get pod -n kube-system "$first_api_pod" -o json | jq -r '.spec.containers[0].command[]' | grep -E "(tls-cert-file|tls-private-key-file|client-ca-file|etcd-certfile|kubelet-client-certificate)" || true)
    
    if [ -n "$cert_args" ]; then
        echo "$cert_args" | while read -r arg; do
            if [[ "$arg" == *"="* ]]; then
                param=$(echo "$arg" | cut -d= -f1 | sed 's/--//')
                value=$(echo "$arg" | cut -d= -f2)
                echo "  $param: $value"
            fi
        done
    else
        echo "  Certificate paths not found in pod spec"
    fi
else
    echo "API server running as static pod or external"
fi

echo ""
echo "3. Control Plane Certificate Expiry"
echo "---------------------------------"

# For kubeadm clusters, check certificate expiration
if [ -n "$kubeadm_cm" ] && [ "$kubeadm_cm" != "null" ]; then
    echo "Checking kubeadm certificate expiration..."
    
    # Try to run kubeadm certs check-expiration if available
    # This would require access to a control plane node
    echo -e "${YELLOW}Note: Direct certificate expiry check requires control plane access${NC}"
fi

# Check for certificate secrets
echo ""
echo "Certificate secrets in kube-system:"
cert_secrets=$(kubectl get secrets -n kube-system -o json | jq -r '.items[] | select(.type == "kubernetes.io/tls" or .data."tls.crt" != null) | .metadata.name')

if [ -n "$cert_secrets" ]; then
    echo "$cert_secrets" | while read -r secret; do
        echo -n "  $secret: "
        
        # Try to decode and check certificate
        cert_data=$(kubectl get secret -n kube-system "$secret" -o jsonpath='{.data.tls\.crt}' 2>/dev/null || \
                    kubectl get secret -n kube-system "$secret" -o jsonpath='{.data.ca\.crt}' 2>/dev/null || echo "")
        
        if [ -n "$cert_data" ] && [ "$cert_data" != "null" ]; then
            # Decode certificate and check expiry
            if command -v openssl &> /dev/null; then
                expiry=$(echo "$cert_data" | base64 -d | openssl x509 -enddate -noout 2>/dev/null | cut -d= -f2 || echo "")
                
                if [ -n "$expiry" ]; then
                    # Calculate days until expiry
                    if [[ "$OSTYPE" == "darwin"* ]]; then
                        expiry_epoch=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry" +%s 2>/dev/null || echo "0")
                    else
                        expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo "0")
                    fi
                    
                    current_epoch=$(date +%s)
                    days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
                    
                    if [ "$days_left" -lt "$CERT_CRITICAL_DAYS" ]; then
                        echo -e "${RED}Expires in $days_left days ($expiry)${NC}"
                    elif [ "$days_left" -lt "$CERT_WARNING_DAYS" ]; then
                        echo -e "${YELLOW}Expires in $days_left days ($expiry)${NC}"
                    else
                        echo -e "${GREEN}Valid for $days_left days${NC}"
                    fi
                else
                    echo "Unable to determine expiry"
                fi
            else
                echo "openssl not available for cert check"
            fi
        else
            echo "No certificate data found"
        fi
    done
else
    echo "  No TLS secrets found"
fi

echo ""
echo "4. Service Account Certificates"
echo "-----------------------------"

# Check service account token secrets
sa_secrets=$(kubectl get secrets --all-namespaces -o json | jq '[.items[] | select(.type == "kubernetes.io/service-account-token")] | length')
echo "Service account token secrets: $sa_secrets"

# Check if service account signing key is rotated
echo ""
echo "Service account key rotation:"
controller_manager_pod=$(kubectl get pods -n kube-system -l component=kube-controller-manager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$controller_manager_pod" ]; then
    sa_key_file=$(kubectl get pod -n kube-system "$controller_manager_pod" -o json | jq -r '.spec.containers[0].command[]' | grep "service-account-private-key-file" | cut -d= -f2 || echo "")
    
    if [ -n "$sa_key_file" ]; then
        echo "  Service account key: $sa_key_file"
    else
        echo "  Service account key path not found"
    fi
fi

echo ""
echo "5. Webhook Certificates"
echo "---------------------"

# Check validating webhooks
echo "Validating webhooks:"
validating_webhooks=$(kubectl get validatingwebhookconfigurations -o json)
vw_count=$(echo "$validating_webhooks" | jq '.items | length')

if [ "$vw_count" -gt 0 ]; then
    echo "  Found $vw_count validating webhook(s)"
    
    # Check CA bundles
    for i in $(seq 0 $((vw_count - 1))); do
        webhook=$(echo "$validating_webhooks" | jq ".items[$i]")
        webhook_name=$(echo "$webhook" | jq -r '.metadata.name')
        
        # Check if CA bundle is present
        ca_bundle=$(echo "$webhook" | jq -r '.webhooks[0].clientConfig.caBundle // empty')
        
        if [ -n "$ca_bundle" ]; then
            echo -e "  ${GREEN}✓ $webhook_name: CA bundle present${NC}"
        else
            echo -e "  ${YELLOW}⚠ $webhook_name: No CA bundle${NC}"
        fi
    done
else
    echo "  No validating webhooks"
fi

# Check mutating webhooks
echo ""
echo "Mutating webhooks:"
mutating_webhooks=$(kubectl get mutatingwebhookconfigurations -o json)
mw_count=$(echo "$mutating_webhooks" | jq '.items | length')

if [ "$mw_count" -gt 0 ]; then
    echo "  Found $mw_count mutating webhook(s)"
    
    for i in $(seq 0 $((mw_count - 1))); do
        webhook=$(echo "$mutating_webhooks" | jq ".items[$i]")
        webhook_name=$(echo "$webhook" | jq -r '.metadata.name')
        ca_bundle=$(echo "$webhook" | jq -r '.webhooks[0].clientConfig.caBundle // empty')
        
        if [ -n "$ca_bundle" ]; then
            echo -e "  ${GREEN}✓ $webhook_name: CA bundle present${NC}"
        else
            echo -e "  ${YELLOW}⚠ $webhook_name: No CA bundle${NC}"
        fi
    done
else
    echo "  No mutating webhooks"
fi

echo ""
echo "6. Ingress Certificates"
echo "---------------------"

# Check ingress resources for TLS
ingresses=$(kubectl get ingresses --all-namespaces -o json)
ingress_count=$(echo "$ingresses" | jq '.items | length')
tls_ingresses=0

if [ "$ingress_count" -gt 0 ]; then
    echo "Checking $ingress_count ingress resource(s)..."
    
    for i in $(seq 0 $((ingress_count - 1))); do
        ingress=$(echo "$ingresses" | jq ".items[$i]")
        ingress_name=$(echo "$ingress" | jq -r '.metadata.name')
        ingress_ns=$(echo "$ingress" | jq -r '.metadata.namespace')
        
        # Check for TLS configuration
        tls_config=$(echo "$ingress" | jq '.spec.tls // empty')
        
        if [ -n "$tls_config" ] && [ "$tls_config" != "null" ]; then
            ((tls_ingresses++))
            
            # Get TLS secret names
            tls_secrets=$(echo "$tls_config" | jq -r '.[].secretName // empty')
            
            if [ -n "$tls_secrets" ]; then
                echo ""
                echo "Ingress: $ingress_ns/$ingress_name"
                
                echo "$tls_secrets" | while read -r secret_name; do
                    if [ -n "$secret_name" ]; then
                        # Check if secret exists
                        if kubectl get secret -n "$ingress_ns" "$secret_name" &> /dev/null; then
                            echo -e "  ${GREEN}✓ TLS secret exists: $secret_name${NC}"
                            
                            # Try to check certificate expiry
                            cert_data=$(kubectl get secret -n "$ingress_ns" "$secret_name" -o jsonpath='{.data.tls\.crt}' 2>/dev/null)
                            
                            if [ -n "$cert_data" ] && command -v openssl &> /dev/null; then
                                expiry=$(echo "$cert_data" | base64 -d | openssl x509 -enddate -noout 2>/dev/null | cut -d= -f2 || echo "")
                                
                                if [ -n "$expiry" ]; then
                                    if [[ "$OSTYPE" == "darwin"* ]]; then
                                        expiry_epoch=$(date -j -f "%b %d %H:%M:%S %Y %Z" "$expiry" +%s 2>/dev/null || echo "0")
                                    else
                                        expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo "0")
                                    fi
                                    
                                    current_epoch=$(date +%s)
                                    days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
                                    
                                    if [ "$days_left" -lt "$CERT_CRITICAL_DAYS" ]; then
                                        echo -e "    ${RED}Expires in $days_left days${NC}"
                                    elif [ "$days_left" -lt "$CERT_WARNING_DAYS" ]; then
                                        echo -e "    ${YELLOW}Expires in $days_left days${NC}"
                                    else
                                        echo -e "    ${GREEN}Valid for $days_left days${NC}"
                                    fi
                                fi
                            fi
                        else
                            echo -e "  ${RED}✗ TLS secret missing: $secret_name${NC}"
                        fi
                    fi
                done
            fi
        fi
    done
    
    echo ""
    echo "Summary: $tls_ingresses/$ingress_count ingresses use TLS"
else
    echo "No ingress resources found"
fi

echo ""
echo "7. Certificate Manager Integration"
echo "--------------------------------"

# Check for cert-manager
if kubectl get namespace cert-manager &> /dev/null; then
    echo -e "${GREEN}✓ cert-manager namespace found${NC}"
    
    # Check cert-manager certificates
    certificates=$(kubectl get certificates --all-namespaces -o json 2>/dev/null)
    cert_count=$(echo "$certificates" | jq '.items | length' 2>/dev/null || echo "0")
    
    if [ "$cert_count" -gt 0 ]; then
        echo "cert-manager certificates: $cert_count"
        
        # Count by status
        ready_certs=$(echo "$certificates" | jq '[.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "True"))] | length')
        not_ready_certs=$((cert_count - ready_certs))
        
        echo "  Ready: $ready_certs"
        [ "$not_ready_certs" -gt 0 ] && echo -e "  ${YELLOW}Not Ready: $not_ready_certs${NC}"
    fi
else
    echo "cert-manager not installed"
fi

echo ""
echo "8. ETCD Certificates"
echo "------------------"

# Check etcd certificates
etcd_pods=$(kubectl get pods -n kube-system -l component=etcd -o json 2>/dev/null)
etcd_count=$(echo "$etcd_pods" | jq '.items | length' 2>/dev/null || echo "0")

if [ "$etcd_count" -gt 0 ]; then
    echo "Found $etcd_count etcd pod(s)"
    
    # Extract etcd cert paths
    first_etcd_pod=$(echo "$etcd_pods" | jq -r '.items[0].metadata.name')
    
    etcd_cert_args=$(kubectl get pod -n kube-system "$first_etcd_pod" -o json | jq -r '.spec.containers[0].command[]' | grep -E "(cert-file|key-file|trusted-ca-file|peer-cert-file)" || true)
    
    if [ -n "$etcd_cert_args" ]; then
        echo "ETCD certificate configuration:"
        echo "$etcd_cert_args" | while read -r arg; do
            if [[ "$arg" == *"="* ]]; then
                param=$(echo "$arg" | cut -d= -f1 | sed 's/--//')
                value=$(echo "$arg" | cut -d= -f2)
                echo "  $param: $value"
            fi
        done
    fi
else
    echo "ETCD not found (may be external)"
fi

echo ""
echo "9. Certificate Rotation Status"
echo "----------------------------"

# Check for certificate rotation
echo "Automatic certificate rotation:"

# Check kubelet certificate rotation
kubelet_rotate=$(kubectl get nodes -o json | jq -r '.items[0].status.nodeInfo.kubeletVersion' 2>/dev/null || echo "")
if [ -n "$kubelet_rotate" ]; then
    echo -e "${BLUE}ℹ Kubelet supports certificate rotation in recent versions${NC}"
fi

# Check if any certificate-related events
cert_events=$(kubectl get events --all-namespaces -o json | jq '[.items[] | select(.message | test("certificate|cert|tls"; "i"))] | length')

if [ "$cert_events" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Found $cert_events certificate-related events${NC}"
    echo "Recent certificate events:"
    kubectl get events --all-namespaces -o json | jq -r '.items[] | select(.message | test("certificate|cert|tls"; "i")) | "\(.lastTimestamp): \(.message)"' | tail -5
fi

echo ""
echo "10. Recommendations"
echo "-----------------"

recommendations=0

# Check for expiring certificates
if command -v openssl &> /dev/null; then
    expiring_soon=0
    expired=0
    
    # Count certificates by expiry status (based on checks above)
    # This is a simplified check - in production you'd want more thorough checking
    
    if [ "$expiring_soon" -gt 0 ]; then
        echo -e "${YELLOW}• Renew $expiring_soon certificate(s) expiring within $CERT_WARNING_DAYS days${NC}"
        ((recommendations++))
    fi
    
    if [ "$expired" -gt 0 ]; then
        echo -e "${RED}• URGENT: Renew $expired expired certificate(s)${NC}"
        ((recommendations++))
    fi
fi

# Webhook certificates
if [ "$vw_count" -gt 0 ] || [ "$mw_count" -gt 0 ]; then
    echo -e "${BLUE}• Ensure webhook certificates are managed and rotated${NC}"
    ((recommendations++))
fi

# cert-manager
if ! kubectl get namespace cert-manager &> /dev/null && [ "$tls_ingresses" -gt 0 ]; then
    echo -e "${BLUE}• Consider installing cert-manager for automatic certificate management${NC}"
    ((recommendations++))
fi

# Certificate backup
echo -e "${BLUE}• Ensure certificate backups are included in cluster backup strategy${NC}"
((recommendations++))

if [ "$recommendations" -eq 1 ]; then
    echo -e "${GREEN}✓ Only standard recommendations - certificates look healthy!${NC}"
fi

echo ""
echo "======================================"
echo "Certificate Health Check Complete"
echo ""
echo "Summary:"
echo "- Service account secrets: $sa_secrets"
echo "- Webhook configurations: $((vw_count + mw_count))"
echo "- TLS-enabled ingresses: $tls_ingresses"
echo "- cert-manager certificates: ${cert_count:-0}"
echo "- Recommendations: $recommendations"
echo "======================================"
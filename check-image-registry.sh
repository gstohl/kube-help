#!/bin/bash

# Image Registry Health Check Script
# This script analyzes container image usage and registry configuration

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
echo "Container Image Registry Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

echo "1. Image Usage Analysis"
echo "---------------------"

# Get all pods and their images
all_pods=$(kubectl get pods --all-namespaces -o json)
total_pods=$(echo "$all_pods" | jq '.items | length')

echo "Analyzing images across $total_pods pods..."
echo ""

# Extract all images
all_images=$(echo "$all_pods" | jq -r '.items[].spec.containers[].image' | sort | uniq)
total_unique_images=$(echo "$all_images" | wc -l)

echo "Total unique images: $total_unique_images"

# Analyze images by registry
echo ""
echo "Images by Registry:"
declare -A registry_counts
declare -A registry_examples

while IFS= read -r image; do
    # Extract registry from image
    if [[ "$image" == *"/"* ]]; then
        registry=$(echo "$image" | cut -d'/' -f1)
        
        # Check if it's a registry URL (contains dots or ports)
        if [[ "$registry" == *"."* ]] || [[ "$registry" == *":"* ]]; then
            ((registry_counts[$registry]++))
            registry_examples[$registry]="$image"
        else
            # Likely Docker Hub official image or short name
            ((registry_counts["docker.io"]++))
            registry_examples["docker.io"]="$image"
        fi
    else
        # No slash, likely a local or Docker Hub official image
        ((registry_counts["docker.io"]++))
        registry_examples["docker.io"]="$image"
    fi
done <<< "$all_images"

# Display registry distribution
for registry in "${!registry_counts[@]}"; do
    count=${registry_counts[$registry]}
    percentage=$((count * 100 / total_unique_images))
    echo "  $registry: $count images ($percentage%)"
    echo "    Example: ${registry_examples[$registry]}"
done

echo ""
echo "2. Image Pull Secrets"
echo "-------------------"

# Get all image pull secrets
pull_secrets=$(kubectl get secrets --all-namespaces -o json | jq -r '.items[] | select(.type == "kubernetes.io/dockerconfigjson" or .type == "kubernetes.io/dockercfg") | "\(.metadata.namespace)/\(.metadata.name)"')
secret_count=$(echo "$pull_secrets" | grep -v "^$" | wc -l || echo "0")

echo "Total image pull secrets: $secret_count"

if [ "$secret_count" -gt 0 ]; then
    echo ""
    echo "Pull secrets by namespace:"
    echo "$pull_secrets" | grep -v "^$" | cut -d'/' -f1 | sort | uniq -c | sort -rn | head -10
    
    # Check which registries are configured
    echo ""
    echo "Configured registries in secrets:"
    
    while IFS= read -r secret; do
        if [ -n "$secret" ]; then
            ns=$(echo "$secret" | cut -d'/' -f1)
            name=$(echo "$secret" | cut -d'/' -f2)
            
            # Get the docker config
            docker_config=$(kubectl get secret -n "$ns" "$name" -o json | jq -r '.data.".dockerconfigjson" // .data.".dockercfg" // empty' | base64 -d 2>/dev/null || echo "{}")
            
            if [ -n "$docker_config" ] && [ "$docker_config" != "{}" ]; then
                registries=$(echo "$docker_config" | jq -r '.auths | keys[]' 2>/dev/null || echo "")
                
                if [ -n "$registries" ]; then
                    echo "$registries" | while read -r reg; do
                        echo "  $reg (in $secret)"
                    done | sort | uniq
                fi
            fi
        fi
    done <<< "$pull_secrets" | sort | uniq
fi

echo ""
echo "3. Image Pull Errors"
echo "------------------"

# Check for image pull errors
pull_events=$(kubectl get events --all-namespaces --field-selector reason=Failed -o json | jq '.items[] | select(.message | test("pull|Pull|image|Image"))')
pull_error_count=$(echo "$pull_events" | jq -s 'length')

echo "Image pull errors in recent events: $pull_error_count"

if [ "$pull_error_count" -gt 0 ]; then
    echo ""
    echo "Error breakdown:"
    
    # Categorize errors
    not_found=$(echo "$pull_events" | jq -s '[.[] | select(.message | test("not found|not exist"))] | length')
    auth_errors=$(echo "$pull_events" | jq -s '[.[] | select(.message | test("unauthorized|authentication|forbidden"))] | length')
    network_errors=$(echo "$pull_events" | jq -s '[.[] | select(.message | test("timeout|connection|network"))] | length')
    rate_limit=$(echo "$pull_events" | jq -s '[.[] | select(.message | test("rate limit|too many requests"))] | length')
    
    [ "$not_found" -gt 0 ] && echo -e "  ${YELLOW}Image not found: $not_found${NC}"
    [ "$auth_errors" -gt 0 ] && echo -e "  ${RED}Authentication failures: $auth_errors${NC}"
    [ "$network_errors" -gt 0 ] && echo -e "  ${YELLOW}Network/timeout errors: $network_errors${NC}"
    [ "$rate_limit" -gt 0 ] && echo -e "  ${RED}Rate limit errors: $rate_limit${NC}"
    
    echo ""
    echo "Recent pull errors (last 5):"
    echo "$pull_events" | jq -s -r '.[-5:] | .[] | "\(.firstTimestamp): \(.involvedObject.namespace)/\(.involvedObject.name) - \(.message)"'
fi

echo ""
echo "4. Image Security Analysis"
echo "------------------------"

# Check for risky image patterns
echo "Checking for security concerns..."

# Images using latest tag
latest_images=$(echo "$all_images" | grep ":latest$" | wc -l || echo "0")
no_tag_images=$(echo "$all_images" | grep -v ":" | wc -l || echo "0")
total_risky=$((latest_images + no_tag_images))

echo "Images with non-specific tags:"
echo "  Using 'latest' tag: $latest_images"
echo "  No tag specified: $no_tag_images"

if [ "$total_risky" -gt 0 ]; then
    echo -e "${YELLOW}⚠ $total_risky images use non-specific tags${NC}"
    echo ""
    echo "Examples of risky images:"
    echo "$all_images" | grep -E ":latest$|^[^:]+$" | head -5 | sed 's/^/  /'
fi

# Check for images from public registries
public_images=0
while IFS= read -r image; do
    if [[ ! "$image" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/.*$ ]] && [[ "$image" =~ ^[^/]+/[^/]+$ ]]; then
        # Likely a Docker Hub public image
        ((public_images++))
    fi
done <<< "$all_images"

echo ""
echo "Public registry usage:"
echo "  Potential public images: $public_images"

echo ""
echo "5. Registry Endpoint Health"
echo "-------------------------"

# Check if there are any in-cluster registries
registry_services=$(kubectl get services --all-namespaces -o json | jq -r '.items[] | select(.metadata.name | test("registry|harbor|quay|artifactory|nexus")) | "\(.metadata.namespace)/\(.metadata.name)"')
registry_svc_count=$(echo "$registry_services" | grep -v "^$" | wc -l || echo "0")

if [ "$registry_svc_count" -gt 0 ]; then
    echo "Found $registry_svc_count potential registry service(s):"
    
    while IFS= read -r svc; do
        if [ -n "$svc" ]; then
            ns=$(echo "$svc" | cut -d'/' -f1)
            name=$(echo "$svc" | cut -d'/' -f2)
            
            # Get service details
            svc_info=$(kubectl get service -n "$ns" "$name" -o json)
            svc_type=$(echo "$svc_info" | jq -r '.spec.type')
            cluster_ip=$(echo "$svc_info" | jq -r '.spec.clusterIP')
            
            echo ""
            echo "  Service: $svc"
            echo "    Type: $svc_type"
            echo "    ClusterIP: $cluster_ip"
            
            # Check if service has endpoints
            endpoints=$(kubectl get endpoints -n "$ns" "$name" -o json | jq '.subsets[0].addresses | length' 2>/dev/null || echo "0")
            
            if [ "$endpoints" -gt 0 ]; then
                echo -e "    ${GREEN}✓ Endpoints: $endpoints${NC}"
            else
                echo -e "    ${RED}✗ No endpoints${NC}"
            fi
        fi
    done <<< "$registry_services"
else
    echo "No in-cluster registry services detected"
fi

echo ""
echo "6. Image Size Analysis"
echo "--------------------"

# Note: We can't get actual image sizes without direct registry access
# But we can analyze image patterns
echo "Analyzing image patterns for size concerns..."

# Check for known large images
large_image_patterns=("tensorflow" "pytorch" "cuda" "spark" "jupyter" "anaconda")
large_images_found=0

for pattern in "${large_image_patterns[@]}"; do
    count=$(echo "$all_images" | grep -i "$pattern" | wc -l || echo "0")
    if [ "$count" -gt 0 ]; then
        echo "  Found $count images matching '$pattern' (typically large)"
        ((large_images_found+=count))
    fi
done

if [ "$large_images_found" -eq 0 ]; then
    echo -e "${GREEN}✓ No known large image patterns detected${NC}"
fi

echo ""
echo "7. Image Pull Policy Analysis"
echo "---------------------------"

# Check image pull policies
echo "Analyzing image pull policies..."

always_pull=$(echo "$all_pods" | jq '[.items[].spec.containers[] | select(.imagePullPolicy == "Always")] | length')
if_not_present=$(echo "$all_pods" | jq '[.items[].spec.containers[] | select(.imagePullPolicy == "IfNotPresent" or .imagePullPolicy == null)] | length')
never_pull=$(echo "$all_pods" | jq '[.items[].spec.containers[] | select(.imagePullPolicy == "Never")] | length')

total_containers=$((always_pull + if_not_present + never_pull))

echo "Pull policy distribution:"
echo "  Always: $always_pull ($((always_pull * 100 / total_containers))%)"
echo "  IfNotPresent: $if_not_present ($((if_not_present * 100 / total_containers))%)"
[ "$never_pull" -gt 0 ] && echo "  Never: $never_pull"

# Warn about Always with latest
latest_always=$(echo "$all_pods" | jq '[.items[].spec.containers[] | select(.image | endswith(":latest")) | select(.imagePullPolicy == "Always")] | length')
if [ "$latest_always" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}⚠ $latest_always container(s) use 'latest' tag with 'Always' pull policy${NC}"
    echo "  This can cause inconsistent deployments"
fi

echo ""
echo "8. Registry Mirror Configuration"
echo "------------------------------"

# Check for registry mirror configuration in nodes
echo "Checking for registry mirror configuration..."

# This would require checking container runtime config on nodes
# We can check for common mirror-related ConfigMaps
mirror_configs=$(kubectl get configmaps --all-namespaces -o json | jq -r '.items[] | select(.metadata.name | test("mirror|registry-config|containerd-config")) | "\(.metadata.namespace)/\(.metadata.name)"' | head -5)

if [ -n "$mirror_configs" ]; then
    echo "Potential mirror configurations found:"
    echo "$mirror_configs"
else
    echo "No obvious mirror configurations found in ConfigMaps"
fi

echo ""
echo "9. Private Registry Usage"
echo "-----------------------"

# Identify private registries
echo "Identifying private registry usage..."

private_registries=()
for registry in "${!registry_counts[@]}"; do
    # Check if it looks like a private registry (has domain but not common public ones)
    if [[ "$registry" =~ \. ]] && 
       [[ ! "$registry" =~ (docker\.io|gcr\.io|quay\.io|ghcr\.io|mcr\.microsoft\.com|public\.ecr\.aws) ]]; then
        private_registries+=("$registry")
    fi
done

if [ ${#private_registries[@]} -gt 0 ]; then
    echo "Private registries detected:"
    for reg in "${private_registries[@]}"; do
        echo "  $reg: ${registry_counts[$reg]} images"
    done
else
    echo "No private registries detected"
fi

echo ""
echo "10. Recommendations"
echo "-----------------"

recommendations=0

# Tag recommendations
if [ "$total_risky" -gt 10 ]; then
    echo -e "${YELLOW}• Use specific version tags instead of 'latest' ($total_risky risky images)${NC}"
    ((recommendations++))
fi

# Pull secret recommendations
if [ "$auth_errors" -gt 0 ]; then
    echo -e "${RED}• Fix authentication errors - check image pull secrets${NC}"
    ((recommendations++))
fi

# Rate limit recommendations
if [ "$rate_limit" -gt 0 ]; then
    echo -e "${RED}• Configure registry mirrors or authenticated pulls to avoid rate limits${NC}"
    ((recommendations++))
fi

# Pull policy recommendations
if [ "$latest_always" -gt 0 ]; then
    echo -e "${YELLOW}• Avoid using 'Always' pull policy with 'latest' tag${NC}"
    ((recommendations++))
fi

# Security recommendations
if [ "$public_images" -gt $((total_unique_images / 2)) ]; then
    echo -e "${BLUE}• Consider using private registry for better security and control${NC}"
    ((recommendations++))
fi

# Mirror recommendations
if [ ${#registry_counts[@]} -eq 1 ] && [[ "${!registry_counts[@]}" == *"docker.io"* ]]; then
    echo -e "${BLUE}• Configure registry mirrors for Docker Hub to improve reliability${NC}"
    ((recommendations++))
fi

# Large image recommendations
if [ "$large_images_found" -gt 5 ]; then
    echo -e "${BLUE}• Consider using slimmer base images for large applications${NC}"
    ((recommendations++))
fi

if [ "$recommendations" -eq 0 ]; then
    echo -e "${GREEN}✓ Image registry configuration looks good!${NC}"
fi

echo ""
echo "======================================"
echo "Image Registry Health Check Complete"
echo ""
echo "Summary:"
echo "- Total unique images: $total_unique_images"
echo "- Registries used: ${#registry_counts[@]}"
echo "- Image pull secrets: $secret_count"
echo "- Pull errors: $pull_error_count"
echo "- Risky image tags: $total_risky"
echo "- Recommendations: $recommendations"
echo "======================================"
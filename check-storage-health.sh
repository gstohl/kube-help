#!/bin/bash

# Persistent Storage Health Check Script
# This script performs comprehensive checks on Kubernetes storage resources

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
echo "Kubernetes Storage Health Check"
echo "======================================"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl command not found. Please install kubectl.${NC}"
    exit 1
fi

echo "1. Storage Classes Overview"
echo "-------------------------"

# Get all storage classes
storage_classes=$(kubectl get storageclass -o json)
sc_count=$(echo "$storage_classes" | jq '.items | length')

if [ "$sc_count" -eq 0 ]; then
    echo -e "${RED}✗ No storage classes found${NC}"
    echo "  Storage classes are required for dynamic provisioning"
else
    echo "Total storage classes: $sc_count"
    echo ""
    
    # Display storage classes with details
    echo "Storage Class Details:"
    echo "━━━━━━━━━━━━━━━━━━━━━"
    
    for i in $(seq 0 $((sc_count - 1))); do
        sc=$(echo "$storage_classes" | jq ".items[$i]")
        name=$(echo "$sc" | jq -r '.metadata.name')
        provisioner=$(echo "$sc" | jq -r '.provisioner')
        reclaim_policy=$(echo "$sc" | jq -r '.reclaimPolicy // "Delete"')
        binding_mode=$(echo "$sc" | jq -r '.volumeBindingMode // "Immediate"')
        allow_expansion=$(echo "$sc" | jq -r '.allowVolumeExpansion // false')
        is_default=$(echo "$sc" | jq -r '.metadata.annotations."storageclass.kubernetes.io/is-default-class" // "false"')
        
        echo -e "${BLUE}$name${NC}"
        [ "$is_default" = "true" ] && echo -e "  ${GREEN}✓ Default storage class${NC}"
        echo "  Provisioner: $provisioner"
        echo "  Reclaim Policy: $reclaim_policy"
        echo "  Binding Mode: $binding_mode"
        echo "  Volume Expansion: $([ "$allow_expansion" = "true" ] && echo "Allowed" || echo "Not allowed")"
        
        # Check for common provisioners
        case "$provisioner" in
            *"aws"*)
                echo "  Type: AWS EBS"
                ;;
            *"gce"*|*"gke"*)
                echo "  Type: Google Persistent Disk"
                ;;
            *"azure"*)
                echo "  Type: Azure Disk"
                ;;
            *"csi"*)
                echo "  Type: CSI Driver"
                ;;
            *"nfs"*)
                echo "  Type: NFS"
                ;;
            *"ceph"*|*"rbd"*)
                echo "  Type: Ceph/RBD"
                ;;
            *"longhorn"*)
                echo "  Type: Longhorn"
                ;;
            *"local"*)
                echo "  Type: Local Storage"
                ;;
        esac
        echo ""
    done
    
    # Check for default storage class
    default_count=$(echo "$storage_classes" | jq '[.items[] | select(.metadata.annotations."storageclass.kubernetes.io/is-default-class" == "true")] | length')
    if [ "$default_count" -eq 0 ]; then
        echo -e "${YELLOW}⚠ No default storage class set${NC}"
        echo "  Set a default with: kubectl patch storageclass <name> -p '{\"metadata\": {\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'"
    elif [ "$default_count" -gt 1 ]; then
        echo -e "${YELLOW}⚠ Multiple default storage classes found ($default_count)${NC}"
    fi
fi

echo ""
echo "2. Persistent Volumes Analysis"
echo "----------------------------"

# Get all PVs
pvs=$(kubectl get pv -o json)
total_pvs=$(echo "$pvs" | jq '.items | length')

if [ "$total_pvs" -eq 0 ]; then
    echo "No Persistent Volumes found"
else
    echo "Total Persistent Volumes: $total_pvs"
    echo ""
    
    # PV status breakdown
    echo "PV Status Distribution:"
    for status in "Bound" "Available" "Released" "Failed" "Pending"; do
        count=$(echo "$pvs" | jq "[.items[] | select(.status.phase == \"$status\")] | length")
        if [ "$count" -gt 0 ]; then
            case "$status" in
                "Bound")
                    echo -e "  ${GREEN}✓ $status: $count${NC}"
                    ;;
                "Available")
                    echo -e "  ${BLUE}ℹ $status: $count${NC}"
                    ;;
                "Released")
                    echo -e "  ${YELLOW}⚠ $status: $count${NC}"
                    ;;
                "Failed")
                    echo -e "  ${RED}✗ $status: $count${NC}"
                    ;;
                *)
                    echo "  $status: $count"
                    ;;
            esac
        fi
    done
    
    # Calculate total capacity
    echo ""
    echo "Storage Capacity Summary:"
    
    # Group by storage class and calculate totals
    echo "$pvs" | jq -r '
        .items | 
        group_by(.spec.storageClassName // "no-storage-class") | 
        map({
            storageClass: .[0].spec.storageClassName // "no-storage-class",
            count: length,
            totalCapacity: map(.spec.capacity.storage | 
                if test("Gi$") then (. | rtrimstr("Gi") | tonumber)
                elif test("Mi$") then (. | rtrimstr("Mi") | tonumber / 1024)
                elif test("Ti$") then (. | rtrimstr("Ti") | tonumber * 1024)
                else 0
                end) | add
        }) | 
        .[] | 
        "  \(.storageClass): \(.count) PVs, \(.totalCapacity)Gi total"'
    
    # Show problematic PVs
    failed_pvs=$(echo "$pvs" | jq '[.items[] | select(.status.phase == "Failed")] | length')
    released_pvs=$(echo "$pvs" | jq '[.items[] | select(.status.phase == "Released")] | length')
    
    if [ "$failed_pvs" -gt 0 ] || [ "$released_pvs" -gt 0 ]; then
        echo ""
        echo "Problematic PVs:"
        
        if [ "$failed_pvs" -gt 0 ]; then
            echo -e "${RED}Failed PVs:${NC}"
            echo "$pvs" | jq -r '.items[] | select(.status.phase == "Failed") | "  \(.metadata.name): \(.status.message // "No message")"'
        fi
        
        if [ "$released_pvs" -gt 0 ]; then
            echo -e "${YELLOW}Released PVs (may need cleanup):${NC}"
            echo "$pvs" | jq -r '.items[] | select(.status.phase == "Released") | "  \(.metadata.name): was bound to \(.spec.claimRef.namespace)/\(.spec.claimRef.name)"'
        fi
    fi
fi

echo ""
echo "3. Persistent Volume Claims Analysis"
echo "----------------------------------"

# Get all PVCs
pvcs=$(kubectl get pvc --all-namespaces -o json)
total_pvcs=$(echo "$pvcs" | jq '.items | length')

if [ "$total_pvcs" -eq 0 ]; then
    echo "No Persistent Volume Claims found"
else
    echo "Total Persistent Volume Claims: $total_pvcs"
    echo ""
    
    # PVC status breakdown
    echo "PVC Status Distribution:"
    bound_pvcs=$(echo "$pvcs" | jq '[.items[] | select(.status.phase == "Bound")] | length')
    pending_pvcs=$(echo "$pvcs" | jq '[.items[] | select(.status.phase == "Pending")] | length')
    lost_pvcs=$(echo "$pvcs" | jq '[.items[] | select(.status.phase == "Lost")] | length')
    
    echo -e "  ${GREEN}✓ Bound: $bound_pvcs${NC}"
    [ "$pending_pvcs" -gt 0 ] && echo -e "  ${YELLOW}⚠ Pending: $pending_pvcs${NC}"
    [ "$lost_pvcs" -gt 0 ] && echo -e "  ${RED}✗ Lost: $lost_pvcs${NC}"
    
    # PVC by namespace
    echo ""
    echo "PVCs by Namespace (top 10):"
    echo "$pvcs" | jq -r '
        .items | 
        group_by(.metadata.namespace) | 
        map({namespace: .[0].metadata.namespace, count: length}) | 
        sort_by(.count) | reverse | .[0:10] | 
        .[] | 
        "  \(.namespace): \(.count) PVCs"'
    
    # Show pending PVCs with details
    if [ "$pending_pvcs" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Pending PVCs:${NC}"
        echo "$pvcs" | jq -r '.items[] | 
            select(.status.phase == "Pending") | 
            "\(.metadata.namespace)/\(.metadata.name): \(.spec.resources.requests.storage) requested"' | head -10
        
        # Check events for pending PVCs
        echo ""
        echo "Recent events for pending PVCs:"
        for pvc in $(echo "$pvcs" | jq -r '.items[] | select(.status.phase == "Pending") | "\(.metadata.namespace)/\(.metadata.name)"' | head -5); do
            ns=$(echo "$pvc" | cut -d'/' -f1)
            name=$(echo "$pvc" | cut -d'/' -f2)
            events=$(kubectl get events -n "$ns" --field-selector involvedObject.name="$name" -o json | jq -r '.items[-1].message' 2>/dev/null || echo "No events")
            echo "  $pvc: $events"
        done
    fi
    
    # Check for PVCs without pods
    echo ""
    echo "Checking PVC usage..."
    unused_pvcs=0
    
    for i in $(seq 0 $((total_pvcs - 1))); do
        pvc=$(echo "$pvcs" | jq ".items[$i]")
        pvc_name=$(echo "$pvc" | jq -r '.metadata.name')
        pvc_namespace=$(echo "$pvc" | jq -r '.metadata.namespace')
        
        # Check if any pod is using this PVC
        pods_using=$(kubectl get pods -n "$pvc_namespace" -o json | jq "[.items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName == \"$pvc_name\")] | length")
        
        if [ "$pods_using" -eq 0 ]; then
            ((unused_pvcs++))
        fi
    done
    
    echo "PVC Usage:"
    echo "  Used PVCs: $((total_pvcs - unused_pvcs))"
    echo "  Unused PVCs: $unused_pvcs"
    
    if [ "$unused_pvcs" -gt 0 ]; then
        echo -e "  ${YELLOW}⚠ Consider reviewing unused PVCs for cleanup${NC}"
    fi
fi

echo ""
echo "4. Volume Snapshot Analysis"
echo "-------------------------"

# Check if VolumeSnapshot CRDs are installed
if kubectl api-resources | grep -q "volumesnapshots"; then
    echo "VolumeSnapshot support detected"
    
    # Get volume snapshots
    snapshots=$(kubectl get volumesnapshots --all-namespaces -o json 2>/dev/null)
    snapshot_count=$(echo "$snapshots" | jq '.items | length')
    
    echo "Total Volume Snapshots: $snapshot_count"
    
    if [ "$snapshot_count" -gt 0 ]; then
        # Snapshot status
        ready_snapshots=$(echo "$snapshots" | jq '[.items[] | select(.status.readyToUse == true)] | length')
        echo "  Ready snapshots: $ready_snapshots"
        
        # Snapshots by namespace
        echo ""
        echo "Snapshots by namespace:"
        echo "$snapshots" | jq -r '.items | group_by(.metadata.namespace) | .[] | "\(.[0].metadata.namespace): \(length) snapshots"'
    fi
    
    # Check snapshot classes
    snapshot_classes=$(kubectl get volumesnapshotclasses -o json 2>/dev/null)
    sc_count=$(echo "$snapshot_classes" | jq '.items | length')
    
    if [ "$sc_count" -gt 0 ]; then
        echo ""
        echo "Volume Snapshot Classes: $sc_count"
        echo "$snapshot_classes" | jq -r '.items[] | "  \(.metadata.name) - Driver: \(.driver)"'
    fi
else
    echo "VolumeSnapshot CRDs not installed"
    echo "  Volume snapshotting is not available"
fi

echo ""
echo "5. CSI Drivers and Plugins"
echo "------------------------"

# Check for CSI drivers
csi_drivers=$(kubectl get csidrivers -o json 2>/dev/null)
csi_count=$(echo "$csi_drivers" | jq '.items | length' 2>/dev/null || echo "0")

if [ "$csi_count" -gt 0 ]; then
    echo "CSI Drivers installed: $csi_count"
    echo ""
    
    for i in $(seq 0 $((csi_count - 1))); do
        driver=$(echo "$csi_drivers" | jq ".items[$i]")
        name=$(echo "$driver" | jq -r '.metadata.name')
        attach_required=$(echo "$driver" | jq -r '.spec.attachRequired // true')
        pod_info_mount=$(echo "$driver" | jq -r '.spec.podInfoOnMount // false')
        volume_lifecycle=$(echo "$driver" | jq -r '.spec.volumeLifecycleModes // []')
        
        echo "CSI Driver: $name"
        echo "  Attach Required: $attach_required"
        echo "  Pod Info on Mount: $pod_info_mount"
        [ -n "$volume_lifecycle" ] && echo "  Volume Lifecycle Modes: $volume_lifecycle"
        
        # Check for CSI pods
        csi_pods=$(kubectl get pods --all-namespaces -l "app in ($name,csi-$name)" -o json 2>/dev/null | jq '.items | length' || echo "0")
        if [ "$csi_pods" -gt 0 ]; then
            echo -e "  ${GREEN}✓ CSI pods running: $csi_pods${NC}"
        fi
        echo ""
    done
else
    echo "No CSI drivers found"
    echo "  Using in-tree volume plugins or legacy provisioners"
fi

echo ""
echo "6. Storage Capacity Tracking"
echo "--------------------------"

# Check if storage capacity tracking is enabled
if kubectl get csistoragecapacities --all-namespaces &> /dev/null; then
    echo "CSI Storage Capacity Tracking enabled"
    
    capacities=$(kubectl get csistoragecapacities --all-namespaces -o json)
    capacity_count=$(echo "$capacities" | jq '.items | length')
    
    if [ "$capacity_count" -gt 0 ]; then
        echo "Storage capacity objects: $capacity_count"
        
        # Group by storage class
        echo ""
        echo "Capacity by storage class:"
        echo "$capacities" | jq -r '.items | group_by(.storageClassName) | .[] | "\(.[0].storageClassName): \(length) capacity objects"'
    fi
else
    echo "Storage capacity tracking not available"
fi

echo ""
echo "7. Volume Health Monitoring"
echo "-------------------------"

# Check for volume health monitoring
echo "Checking volume attachment status..."

# Get volume attachments
volume_attachments=$(kubectl get volumeattachments -o json 2>/dev/null)
va_count=$(echo "$volume_attachments" | jq '.items | length' 2>/dev/null || echo "0")

if [ "$va_count" -gt 0 ]; then
    echo "Volume Attachments: $va_count"
    
    attached=$(echo "$volume_attachments" | jq '[.items[] | select(.status.attached == true)] | length')
    echo "  Attached: $attached"
    
    # Check for attachment errors
    attach_errors=$(echo "$volume_attachments" | jq '[.items[] | select(.status.attachError != null)] | length')
    if [ "$attach_errors" -gt 0 ]; then
        echo -e "  ${RED}✗ Attachment errors: $attach_errors${NC}"
        
        echo ""
        echo "Attachment errors:"
        echo "$volume_attachments" | jq -r '.items[] | select(.status.attachError != null) | "  \(.metadata.name): \(.status.attachError.message)"' | head -5
    fi
fi

echo ""
echo "8. Storage Performance Indicators"
echo "-------------------------------"

# Check for storage-related events
echo "Recent storage-related events:"

storage_events=$(kubectl get events --all-namespaces -o json | jq '.items[] | select(.reason | test("Volume|Storage|Mount|Attach|Provision"))')
event_count=$(echo "$storage_events" | jq -s 'length')

if [ "$event_count" -gt 0 ]; then
    # Count by type
    warning_events=$(echo "$storage_events" | jq -s '[.[] | select(.type == "Warning")] | length')
    
    if [ "$warning_events" -gt 0 ]; then
        echo -e "${YELLOW}⚠ Found $warning_events warning events${NC}"
        
        echo ""
        echo "Recent storage warnings:"
        echo "$storage_events" | jq -s -r '.[] | select(.type == "Warning") | "\(.lastTimestamp): \(.reason) - \(.message)"' | tail -10
    else
        echo -e "${GREEN}✓ No storage warning events${NC}"
    fi
fi

echo ""
echo "9. Storage Recommendations"
echo "------------------------"

recommendations=0

# Check for issues and provide recommendations
if [ "$sc_count" -eq 0 ]; then
    echo -e "${RED}• CRITICAL: No storage classes found - dynamic provisioning unavailable${NC}"
    ((recommendations++))
fi

if [ -z "${default_count:-}" ] || [ "${default_count:-0}" -eq 0 ]; then
    echo -e "${YELLOW}• Set a default storage class for easier PVC creation${NC}"
    ((recommendations++))
fi

if [ "${released_pvs:-0}" -gt 0 ]; then
    echo -e "${YELLOW}• Clean up $released_pvs released PVs to free resources${NC}"
    ((recommendations++))
fi

if [ "${pending_pvcs:-0}" -gt 0 ]; then
    echo -e "${YELLOW}• Investigate $pending_pvcs pending PVCs${NC}"
    ((recommendations++))
fi

if [ "${unused_pvcs:-0}" -gt 10 ]; then
    echo -e "${BLUE}• Review $unused_pvcs unused PVCs for potential cleanup${NC}"
    ((recommendations++))
fi

if [ "$csi_count" -eq 0 ]; then
    echo -e "${BLUE}• Consider migrating to CSI drivers for better storage features${NC}"
    ((recommendations++))
fi

if ! kubectl api-resources | grep -q "volumesnapshots"; then
    echo -e "${BLUE}• Install VolumeSnapshot CRDs for backup capabilities${NC}"
    ((recommendations++))
fi

if [ "$recommendations" -eq 0 ]; then
    echo -e "${GREEN}✓ Storage configuration looks good!${NC}"
fi

echo ""
echo "======================================"
echo "Storage Health Check Complete"
echo ""
echo "Summary:"
echo "- Storage Classes: $sc_count"
echo "- Persistent Volumes: $total_pvs (Bound: ${bound_pvs:-0})"
echo "- Persistent Volume Claims: $total_pvcs"
[ "${pending_pvcs:-0}" -gt 0 ] && echo -e "- ${YELLOW}Pending PVCs: $pending_pvcs${NC}"
[ "${unused_pvcs:-0}" -gt 0 ] && echo "- Unused PVCs: $unused_pvcs"
echo "- CSI Drivers: $csi_count"
echo "======================================"
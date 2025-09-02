#!/bin/bash
set -euo pipefail

# Simple Cloud Image Upload Script for Air-Gap vSphere Environment
# Converts and uploads cloud images from files/ directory to vSphere

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="${SCRIPT_DIR}/files"
WORK_DIR="${SCRIPT_DIR}/converted"
LOG_FILE="${SCRIPT_DIR}/upload.log"

# Simple logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR" "$1"
    exit 1
}

# Check prerequisites
check_requirements() {
    log "INFO" "Checking requirements..."
    
    # Check files directory exists
    [[ -d "$FILES_DIR" ]] || error_exit "Files directory not found: $FILES_DIR"
    
    # Check required tools
    command -v qemu-img >/dev/null || error_exit "qemu-img not found. Install qemu-utils package."
    command -v govc >/dev/null || error_exit "govc not found. Download from https://github.com/vmware/govmomi/releases"
    
    # Check govc configuration
    [[ -n "${GOVC_URL:-}" ]] || error_exit "GOVC_URL not set. Configure govc environment variables."
    
    # Test vSphere connection
    govc about >/dev/null || error_exit "Cannot connect to vSphere. Check govc configuration."
    
    log "INFO" "Requirements check passed"
}

# List images in files directory
list_images() {
    log "INFO" "Available images in $FILES_DIR:"
    echo
    
    # Ubuntu OVA files
    find "$FILES_DIR" -name "ubuntu-*.ova" 2>/dev/null | while read -r file; do
        echo "Ubuntu OVA: $(basename "$file")"
    done
    
    # Ubuntu IMG files  
    find "$FILES_DIR" -name "ubuntu-*.img" 2>/dev/null | while read -r file; do
        echo "Ubuntu IMG: $(basename "$file")"
    done
    
    # Debian qcow2 files
    find "$FILES_DIR" -name "debian-*.qcow2" 2>/dev/null | while read -r file; do
        echo "Debian qcow2: $(basename "$file")"
    done
    
    echo
}

# Convert Ubuntu OVA to VMDK
convert_ubuntu_ova() {
    local ova_file="$1"
    local basename="${ova_file##*/}"
    local name_no_ext="${basename%.ova}"
    
    log "INFO" "Converting Ubuntu OVA: $basename"
    
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    # Extract OVA
    tar -xf "$ova_file"
    
    # Find the main VMDK
    local vmdk_file=$(ls *.vmdk | head -n1)
    [[ -n "$vmdk_file" ]] || error_exit "No VMDK found in OVA"
    
    # Convert to vSphere-compatible format
    local output_vmdk="${name_no_ext}.vmdk"
    
    log "INFO" "Converting to vSphere-compatible VMDK..."
    qemu-img convert \
        -f vmdk \
        -O vmdk \
        -o adapter_type=lsilogic,subformat=streamOptimized,compat6 \
        "$vmdk_file" \
        "$output_vmdk" || error_exit "VMDK conversion failed"
    
    # Clean up extraction
    rm -f *.ovf *.mf "$vmdk_file"
    
    echo "$WORK_DIR/$output_vmdk"
}

# Convert Debian qcow2 to VMDK
convert_debian_qcow2() {
    local qcow2_file="$1"
    local basename="${qcow2_file##*/}"
    local name_no_ext="${basename%.qcow2}"
    
    log "INFO" "Converting Debian qcow2: $basename"
    
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    local output_vmdk="${name_no_ext}.vmdk"
    
    log "INFO" "Converting qcow2 to vSphere-compatible VMDK..."
    qemu-img convert \
        -f qcow2 \
        -O vmdk \
        -o adapter_type=lsilogic,subformat=streamOptimized,compat6 \
        "$qcow2_file" \
        "$output_vmdk" || error_exit "qcow2 conversion failed"
    
    echo "$WORK_DIR/$output_vmdk"
}

# Convert Ubuntu IMG to VMDK
convert_ubuntu_img() {
    local img_file="$1"
    local basename="${img_file##*/}"
    local name_no_ext="${basename%.img}"
    
    log "INFO" "Converting Ubuntu IMG: $basename"
    
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    local output_vmdk="${name_no_ext}.vmdk"
    
    log "INFO" "Converting IMG to vSphere-compatible VMDK..."
    qemu-img convert \
        -f raw \
        -O vmdk \
        -o adapter_type=lsilogic,subformat=streamOptimized,compat6 \
        "$img_file" \
        "$output_vmdk" || error_exit "IMG conversion failed"
    
    echo "$WORK_DIR/$output_vmdk"
}

# Upload VMDK to vSphere
upload_vmdk() {
    local vmdk_file="$1"
    local vm_name="$2"
    
    log "INFO" "Uploading $vmdk_file to vSphere as $vm_name..."
    
    # Try govc import.vmdk first (most reliable method)
    if govc import.vmdk \
        -vm "$vm_name" \
        -folder "${GOVC_FOLDER:-}" \
        -pool "${GOVC_RESOURCE_POOL:-*/Resources}" \
        "$vmdk_file" 2>>"$LOG_FILE"; then
        
        log "INFO" "Upload successful using govc import.vmdk"
        
        # Mark as template for Packer to use later
        govc vm.markastemplate "$vm_name"
        log "INFO" "Marked as template: $vm_name"
        return 0
    fi
    
    log "WARN" "govc import.vmdk failed, trying datastore upload method..."
    
    # Alternative: Upload to datastore and create VM manually
    local ds_dir="${vm_name}"
    local ds_path="[${GOVC_DATASTORE}] ${ds_dir}/${vm_name}.vmdk"
    
    # Create directory on datastore
    govc datastore.mkdir "$ds_dir" || true
    
    # Upload VMDK file
    if govc datastore.upload "$vmdk_file" "$ds_path"; then
        log "INFO" "VMDK uploaded to datastore: $ds_path"
        
        # Create VM with the uploaded disk
        if govc vm.create \
            -m 2048 \
            -c 2 \
            -net "${GOVC_NETWORK:-VM Network}" \
            -disk "$ds_path" \
            -disk.controller pvscsi \
            -on=false \
            "$vm_name"; then
            
            log "INFO" "VM created: $vm_name"
            
            # Mark as template
            govc vm.markastemplate "$vm_name"
            log "INFO" "Marked as template: $vm_name"
            return 0
        else
            error_exit "Failed to create VM with uploaded disk"
        fi
    else
        error_exit "Failed to upload VMDK to datastore"
    fi
}

# Process a single image file
process_image() {
    local image_file="$1"
    
    [[ -f "$image_file" ]] || error_exit "Image file not found: $image_file"
    
    local basename="${image_file##*/}"
    local vm_name="template-${basename%.*}"
    
    log "INFO" "Processing: $basename -> $vm_name"
    
    local converted_vmdk=""
    
    case "$basename" in
        ubuntu-*.ova)
            converted_vmdk=$(convert_ubuntu_ova "$image_file")
            ;;
        ubuntu-*.img)
            converted_vmdk=$(convert_ubuntu_img "$image_file")
            ;;
        debian-*.qcow2)
            converted_vmdk=$(convert_debian_qcow2 "$image_file")
            ;;
        *)
            error_exit "Unsupported image format: $basename"
            ;;
    esac
    
    upload_vmdk "$converted_vmdk" "$vm_name"
    
    log "INFO" "Successfully processed: $vm_name"
}

# Process all images in files directory
process_all() {
    log "INFO" "Processing all images in $FILES_DIR..."
    
    local count=0
    local failed=0
    
    # Process all supported image types
    for pattern in "ubuntu-*.ova" "ubuntu-*.img" "debian-*.qcow2"; do
        while IFS= read -r -d '' file; do
            if process_image "$file"; then
                ((count++))
            else
                ((failed++))
                log "ERROR" "Failed to process: $(basename "$file")"
            fi
        done < <(find "$FILES_DIR" -name "$pattern" -print0 2>/dev/null || true)
    done
    
    echo
    log "INFO" "Processing complete: $count successful, $failed failed"
    
    if [[ $count -gt 0 ]]; then
        echo
        log "INFO" "Uploaded templates can now be used in Packer configurations:"
        govc find . -type m -name "template-*" | sed 's|.*/|  - |'
    fi
}

# Clean work directory
clean_work() {
    log "INFO" "Cleaning work directory..."
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    log "INFO" "Work directory cleaned"
}

# Show current vSphere templates
show_templates() {
    log "INFO" "Current templates in vSphere:"
    echo
    
    govc find . -type m -name "template-*" | while read -r template; do
        local name="${template##*/}"
        echo "Template: $name"
        
        # Get some basic info
        local info=$(govc vm.info "$template" 2>/dev/null || echo "Info unavailable")
        echo "  Status: $(echo "$info" | grep -E "Power state|Template" | head -1 || echo "Template")"
        echo
    done
}

# Test vSphere connection
test_connection() {
    log "INFO" "Testing vSphere connection..."
    echo
    
    echo "vCenter Information:"
    govc about
    echo
    
    echo "Configured datastore: ${GOVC_DATASTORE:-Not set}"
    echo "Configured network: ${GOVC_NETWORK:-Not set}"
    echo "Configured folder: ${GOVC_FOLDER:-Default}"
}

# Main menu
show_menu() {
    echo
    echo "====================================="
    echo "  Air-Gap Cloud Image Upload Tool"  
    echo "====================================="
    echo "1) List available images"
    echo "2) Process specific image"
    echo "3) Process all images"
    echo "4) Show vSphere templates"
    echo "5) Clean work directory"
    echo "6) Test vSphere connection"
    echo "7) Exit"
    echo
}

# Main function
main() {
    echo "Air-Gap Cloud Image Upload Tool for vSphere"
    echo "============================================"
    
    check_requirements
    list_images
    
    # Handle command line arguments
    if [[ $# -gt 0 ]]; then
        case "$1" in
            "list")
                list_images
                ;;
            "all")
                process_all
                ;;
            "clean")
                clean_work
                ;;
            "templates")
                show_templates
                ;;
            "test")
                test_connection
                ;;
            *)
                # Assume it's a filename
                if [[ -f "$FILES_DIR/$1" ]]; then
                    process_image "$FILES_DIR/$1"
                else
                    error_exit "File not found: $FILES_DIR/$1"
                fi
                ;;
        esac
        exit 0
    fi
    
    # Interactive menu
    while true; do
        show_menu
        read -p "Select option (1-7): " choice
        
        case "$choice" in
            1)
                list_images
                ;;
            2)
                echo
                read -p "Enter image filename: " filename
                if [[ -f "$FILES_DIR/$filename" ]]; then
                    process_image "$FILES_DIR/$filename"
                else
                    log "ERROR" "File not found: $FILES_DIR/$filename"
                fi
                ;;
            3)
                process_all
                ;;
            4)
                show_templates
                ;;
            5)
                clean_work
                ;;
            6)
                test_connection
                ;;
            7)
                log "INFO" "Exiting..."
                exit 0
                ;;
            *)
                log "ERROR" "Invalid option: $choice"
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
    done
}

# Create work directory
mkdir -p "$WORK_DIR"

# Run main function
main "$@"

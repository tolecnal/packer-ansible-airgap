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
    log "INFO" "Scanning for available images..."
    echo
    
    echo "Available images:"
    echo "=================="
    
    local found_images=false
    
    # Ubuntu OVA files
    while IFS= read -r -d '' file; do
        echo "Ubuntu OVA: $(basename "$file")"
        found_images=true
    done < <(find "$FILES_DIR" -name "ubuntu-*.ova" -print0 2>/dev/null || true)
    
    # Ubuntu IMG files  
    while IFS= read -r -d '' file; do
        echo "Ubuntu IMG: $(basename "$file")"
        found_images=true
    done < <(find "$FILES_DIR" -name "ubuntu-*.img" -print0 2>/dev/null || true)
    
    # Debian qcow2 files
    while IFS= read -r -d '' file; do
        echo "Debian qcow2: $(basename "$file")"
        found_images=true
    done < <(find "$FILES_DIR" -name "debian-*.qcow2" -print0 2>/dev/null || true)
    
    if [[ "$found_images" == "false" ]]; then
        echo "No supported image files found in $FILES_DIR"
        echo
        echo "Supported formats:"
        echo "- ubuntu-*.ova"
        echo "- ubuntu-*.img" 
        echo "- debian-*.qcow2"
        echo
        echo "Please check that your files are in: $FILES_DIR"
        
        # Show what's actually in the directory
        echo "Contents of $FILES_DIR:"
        ls -la "$FILES_DIR" 2>/dev/null || echo "Directory doesn't exist or is empty"
    fi
    
    echo
}

# Convert Ubuntu OVA to VMDK
convert_ubuntu_ova() {
    local ova_file="$1"
    local basename="${ova_file##*/}"
    local name_no_ext="${basename%.ova}"
    
    log "INFO" "Converting Ubuntu OVA: $basename"
    log "INFO" "Source: $ova_file"
    
    # Verify source file exists
    if [[ ! -f "$ova_file" ]]; then
        error_exit "Source OVA file not found: $ova_file"
    fi
    
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    log "INFO" "Working in: $(pwd)"
    log "INFO" "Extracting OVA..."
    
    # Extract OVA
    if ! tar -xf "$ova_file"; then
        error_exit "Failed to extract OVA file"
    fi
    
    # Find the main VMDK
    local vmdk_file=$(ls *.vmdk 2>/dev/null | head -n1)
    if [[ -z "$vmdk_file" ]]; then
        log "ERROR" "No VMDK found in extracted OVA contents:"
        ls -la
        error_exit "No VMDK file found in OVA"
    fi
    
    log "INFO" "Found extracted VMDK: $vmdk_file"
    
    # Convert to vSphere-compatible format
    local output_vmdk="${name_no_ext}.vmdk"
    log "INFO" "Converting to: $output_vmdk"
    
    if ! qemu-img convert \
        -f vmdk \
        -O vmdk \
        -o adapter_type=lsilogic,subformat=streamOptimized,compat6 \
        "$vmdk_file" \
        "$output_vmdk"; then
        error_exit "VMDK conversion failed"
    fi
    
    # Verify output file was created
    if [[ ! -f "$output_vmdk" ]]; then
        error_exit "Conversion completed but output file not found: $output_vmdk"
    fi
    
    log "INFO" "Conversion successful: $(ls -lh "$output_vmdk" | awk '{print $5}')"
    
    # Clean up extraction files
    rm -f *.ovf *.mf "$vmdk_file" 2>/dev/null || true
    
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
    local force_overwrite="${3:-false}"
    
    log "INFO" "Uploading $vmdk_file to vSphere as $vm_name..."
    
    # Check if VM/template already exists and handle accordingly
    if govc vm.info "$vm_name" &>/dev/null; then
        if [[ "$force_overwrite" == "true" ]]; then
            log "WARN" "VM/template $vm_name already exists, removing it..."
            
            # Convert template back to VM if it's a template
            if govc vm.info "$vm_name" | grep -q "Template: true"; then
                govc vm.markasvm "$vm_name" 2>/dev/null || true
            fi
            
            # Power off if running
            govc vm.power -off "$vm_name" 2>/dev/null || true
            
            # Destroy existing VM
            govc vm.destroy "$vm_name" || log "WARN" "Could not destroy existing VM: $vm_name"
            
            # Clean up datastore directory if it exists
            govc datastore.rm -f "$vm_name" 2>/dev/null || true
            
            log "INFO" "Existing VM/template $vm_name removed"
        else
            error_exit "VM/template $vm_name already exists. Use -f flag to overwrite or choose a different name."
        fi
    fi
    
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
    
# Alternative: Upload to datastore and create VM manually
    local ds_dir="${vm_name}"
    local ds_path="[${GOVC_DATASTORE}] ${ds_dir}/${vm_name}.vmdk"
    
    # Create directory on datastore
    log "INFO" "Creating datastore directory: $ds_dir"
    govc datastore.mkdir "$ds_dir" 2>/dev/null || true
    
    # Upload VMDK file
    log "INFO" "Uploading VMDK to: $ds_path"
    log "INFO" "Source file: $vmdk_file"
    
    # Verify source file exists before upload
    if [[ ! -f "$vmdk_file" ]]; then
        error_exit "Converted VMDK file not found: $vmdk_file"
    fi
    
    log "INFO" "Source file size: $(ls -lh "$vmdk_file" | awk '{print $5}')"
    
    if govc datastore.upload "$vmdk_file" "$ds_path"; then
        log "INFO" "VMDK uploaded to datastore successfully"
        
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
    local force_overwrite="${2:-false}"
    
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
    
    upload_vmdk "$converted_vmdk" "$vm_name" "$force_overwrite"
    
    log "INFO" "Successfully processed: $vm_name"
}

# Process all images in files directory
process_all() {
    local force_overwrite="${1:-false}"
    
    log "INFO" "Processing all images in $FILES_DIR..."
    
    local count=0
    local failed=0
    
    # Process all supported image types
    for pattern in "ubuntu-*.ova" "ubuntu-*.img" "debian-*.qcow2"; do
        while IFS= read -r -d '' file; do
            if process_image "$file" "$force_overwrite"; then
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
    echo "3) Process specific image (force overwrite)"
    echo "4) Process all images"
    echo "5) Process all images (force overwrite)"
    echo "6) Show vSphere templates"
    echo "7) Clean work directory"
    echo "8) Test vSphere connection"
    echo "9) Exit"
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
                process_all false
                ;;
            "all-force" | "-f" | "--force")
                process_all true
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
                # Check for force flag
                local force_flag=false
                local filename="$1"
                
                if [[ "$1" == "-f" || "$1" == "--force" ]]; then
                    force_flag=true
                    filename="$2"
                elif [[ "$2" == "-f" || "$2" == "--force" ]]; then
                    force_flag=true
                fi
                
                # Process specific file
                if [[ -f "$FILES_DIR/$filename" ]]; then
                    process_image "$FILES_DIR/$filename" "$force_flag"
                else
                    error_exit "File not found: $FILES_DIR/$filename"
                fi
                ;;
        esac
        exit 0
    fi
    
    # Interactive menu
    while true; do
        show_menu
        read -p "Select option (1-9): " choice
        
        case "$choice" in
            1)
                list_images
                ;;
            2)
                echo
                read -p "Enter image filename: " filename
                if [[ -f "$FILES_DIR/$filename" ]]; then
                    process_image "$FILES_DIR/$filename" false
                else
                    log "ERROR" "File not found: $FILES_DIR/$filename"
                fi
                ;;
            3)
                echo
                read -p "Enter image filename: " filename
                if [[ -f "$FILES_DIR/$filename" ]]; then
                    process_image "$FILES_DIR/$filename" true
                else
                    log "ERROR" "File not found: $FILES_DIR/$filename"
                fi
                ;;
            4)
                process_all false
                ;;
            5)
                process_all true
                ;;
            6)
                show_templates
                ;;
            7)
                clean_work
                ;;
            8)
                test_connection
                ;;
            9)
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


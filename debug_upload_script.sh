#!/bin/bash
set -euo pipefail

# Debug script to figure out what's going wrong

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="${SCRIPT_DIR}/files"
WORK_DIR="${SCRIPT_DIR}/converted"

echo "=== DEBUG MODE ==="
echo "Script dir: $SCRIPT_DIR"
echo "Files dir: $FILES_DIR"
echo "Work dir: $WORK_DIR"

# Simple logging without threading issues
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
}

# Test with one specific file
debug_single_file() {
    local ova_file="$FILES_DIR/ubuntu-noble-server-cloudimg-amd64.ova"
    
    echo
    echo "=== DEBUGGING SINGLE FILE ==="
    echo "Source file: $ova_file"
    
    if [[ ! -f "$ova_file" ]]; then
        echo "ERROR: Source file doesn't exist!"
        exit 1
    fi
    
    echo "Source file exists: $(ls -lh "$ova_file")"
    
    # Create clean work directory
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    echo "Working in: $(pwd)"
    
    # Extract OVA
    echo "Extracting OVA..."
    tar -tf "$ova_file" | head -10
    tar -xf "$ova_file"
    
    echo "Extracted files:"
    ls -la
    
    # Find VMDK
    local vmdk_file=$(ls *.vmdk | head -n1)
    echo "Found VMDK: $vmdk_file"
    
    if [[ -z "$vmdk_file" ]]; then
        echo "ERROR: No VMDK found in extraction!"
        exit 1
    fi
    
    echo "VMDK file details: $(ls -lh "$vmdk_file")"
    
    # Convert
    local output_vmdk="ubuntu-noble-server-cloudimg-amd64.vmdk"
    echo "Converting to: $output_vmdk"
    
    if qemu-img convert \
        -f vmdk \
        -O vmdk \
        -o adapter_type=lsilogic,subformat=streamOptimized,compat6 \
        "$vmdk_file" \
        "$output_vmdk"; then
        
        echo "Conversion successful!"
        echo "Output file: $(ls -lh "$output_vmdk")"
        echo "Full path: $WORK_DIR/$output_vmdk"
        
        # Test the full path
        echo "Testing full path:"
        if [[ -f "$WORK_DIR/$output_vmdk" ]]; then
            echo "✓ Full path exists"
            file "$WORK_DIR/$output_vmdk"
        else
            echo "✗ Full path doesn't exist"
        fi
        
        # Test what govc thinks
        echo
        echo "=== TESTING GOVC ==="
        echo "GOVC environment:"
        env | grep GOVC || echo "No GOVC vars set"
        
        if command -v govc >/dev/null; then
            echo "Testing govc connection..."
            if govc about; then
                echo "govc connection works"
                
                # Try to upload
                echo "Testing upload to datastore..."
                local test_path="[${GOVC_DATASTORE}] test-upload/test.vmdk"
                echo "Upload path: $test_path"
                
                # Create test directory
                govc datastore.mkdir -p test-upload
                
                # Try upload
                if govc datastore.upload "$WORK_DIR/$output_vmdk" "$test_path"; then
                    echo "✓ Upload works!"
                    # Clean up
                    govc datastore.rm -f test-upload
                else
                    echo "✗ Upload failed"
                fi
            else
                echo "govc connection failed"
            fi
        else
            echo "govc not found in PATH"
        fi
        
    else
        echo "Conversion failed!"
        exit 1
    fi
}

# Main debug
echo "Starting debug..."
debug_single_file
echo "Debug complete!"

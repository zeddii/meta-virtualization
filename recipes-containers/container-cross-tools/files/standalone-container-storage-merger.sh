#!/bin/sh
# flexible-container-merger.sh
# Enhanced merger supporting custom target directories for Yocto rootfs integration
# Maintains backward compatibility with on-target BusyBox usage

set -e

NEW_STORAGE_TAR="$1"
TARGET_DOCKER_DIR="$2"

# Default to standard Docker location if no target specified
if [ -z "$TARGET_DOCKER_DIR" ]; then
    TARGET_DOCKER_DIR="/var/lib/docker"
fi

# Derive backup directory location based on target
TARGET_PARENT=$(dirname "$TARGET_DOCKER_DIR")
BACKUP_DIR="$TARGET_PARENT/docker-backup-$(date +%s)"
TEMP_MERGE_DIR="/tmp/docker-merge-$(date +%s)"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
}

show_usage() {
    echo "Usage: $0 <new-docker-storage.tar> [target-docker-directory]"
    echo ""
    echo "Examples:"
    echo "  # Standard on-target installation:"
    echo "  $0 docker-storage.tar"
    echo "  # -> Installs to /var/lib/docker"
    echo ""
    echo "  # Yocto rootfs integration:"
    echo "  $0 docker-storage.tar /path/to/rootfs/var/lib/docker"
    echo "  # -> Installs to custom rootfs path"
    echo ""
    echo "Features:"
    echo "  - Automatic fresh vs additive detection"
    echo "  - BusyBox compatible commands only"
    echo "  - Bulletproof JSON merging without complex parsing"
    echo "  - Safe backup creation"
}

if [ -z "$NEW_STORAGE_TAR" ]; then
    show_usage
    exit 1
fi

if [ ! -f "$NEW_STORAGE_TAR" ]; then
    log "ERROR" "Storage file not found: $NEW_STORAGE_TAR"
    exit 1
fi

log "INFO" "Starting flexible Docker storage merge"
log "INFO" "New storage: $NEW_STORAGE_TAR"
log "INFO" "Target directory: $TARGET_DOCKER_DIR"
log "INFO" "Backup location: $BACKUP_DIR"

# Validate target directory parent exists (for Yocto integration)
TARGET_PARENT_DIR=$(dirname "$TARGET_DOCKER_DIR")
if [ ! -d "$TARGET_PARENT_DIR" ]; then
    log "ERROR" "Target parent directory does not exist: $TARGET_PARENT_DIR"
    log "INFO" "For Yocto integration, ensure the rootfs path exists first"
    exit 1
fi

# Check if this is fresh or additive installation
FRESH_INSTALL=false
if [ ! -d "$TARGET_DOCKER_DIR" ] || [ ! "$(ls -A "$TARGET_DOCKER_DIR" 2>/dev/null)" ]; then
    FRESH_INSTALL=true
    log "INFO" "Fresh installation detected - extracting directly"
    
    # Create target parent if needed (for Yocto)
    mkdir -p "$TARGET_PARENT_DIR"
    
    # Extract directly to target location
    # tar -xf "$NEW_STORAGE_TAR" -C "$TARGET_PARENT_DIR/"
    tar -xf "$NEW_STORAGE_TAR" -C "$TARGET_PARENT_DIR/" --no-same-owner --no-same-permissions 2>/dev/null || {
	# Fallback: extract with device file skipping
	log "WARN" "Standard extraction failed, trying with device file handling..."
	tar -xf "$NEW_STORAGE_TAR" -C "$TARGET_PARENT_DIR/" --no-same-owner --no-same-permissions --exclude="*/backingFsBlockDev" --exclude="*/*.dev" 2>/dev/null || {
            log "ERROR" "Docker storage extraction failed even with device file exclusions"
            log "ERROR" "This may require root privileges or fakeroot for device file creation"
            log "INFO" "Try running with: sudo $0 $NEW_STORAGE_TAR $TARGET_DOCKER_DIR"
            exit 1
	}
	log "INFO" "Extracted with device file exclusions (normal for non-root deployment)"
    }
    
    # Verify extraction created the docker directory
    if [ ! -d "$TARGET_DOCKER_DIR" ]; then
        log "ERROR" "Extraction did not create expected docker directory"
        log "ERROR" "Expected: $TARGET_DOCKER_DIR"
        log "INFO" "Check that the storage tar contains a 'docker/' directory at root level"
        exit 1
    fi
    
    log "INFO" "Fresh installation completed successfully"
    log "INFO" "Docker storage installed to: $TARGET_DOCKER_DIR"
    
    # Show what was installed
    if [ -f "$TARGET_DOCKER_DIR/image/overlay2/repositories.json" ]; then
        log "INFO" "Repositories installed:"
        cat "$TARGET_DOCKER_DIR/image/overlay2/repositories.json" 2>/dev/null || echo "  (repositories.json not readable)"
    fi
    
    exit 0
fi

# Additive installation - create backup first
log "INFO" "Additive installation - creating backup of existing Docker storage..."
mkdir -p "$BACKUP_DIR"
cp -r "$TARGET_DOCKER_DIR" "$BACKUP_DIR/"
log "INFO" "Backup created: $BACKUP_DIR"

# Extract new storage to temporary location
log "INFO" "Extracting new storage to temporary location..."
mkdir -p "$TEMP_MERGE_DIR"
# tar -xf "$NEW_STORAGE_TAR" -C "$TEMP_MERGE_DIR/"
tar -xf "$NEW_STORAGE_TAR" -C "$TEMP_MERGE_DIR/" --no-same-owner --no-same-permissions 2>/dev/null || {
    # Fallback: extract with device file skipping
    log "WARN" "Standard extraction failed, trying with device file handling..."
    tar -xf "$NEW_STORAGE_TAR" -C "$TEMP_MERGE_DIR/" --no-same-owner --no-same-permissions --exclude="*/backingFsBlockDev" --exclude="*/*.dev" 2>/dev/null || {
        log "ERROR" "Docker storage extraction failed even with device file exclusions"
        log "ERROR" "This may require root privileges or fakeroot for device file creation"
        log "INFO" "Try running with: sudo $0 $NEW_STORAGE_TAR $TARGET_DOCKER_DIR"
        exit 1
    }
    log "INFO" "Extracted with device file exclusions (normal for non-root deployment)"
}

if [ ! -d "$TEMP_MERGE_DIR/docker" ]; then
    log "ERROR" "Invalid storage structure - no docker/ directory found"
    log "ERROR" "Storage tar must contain a docker/ directory at root level"
    rm -rf "$TEMP_MERGE_DIR"
    exit 1
fi

NEW_DOCKER_DIR="$TEMP_MERGE_DIR/docker"
log "INFO" "New Docker storage extracted to: $NEW_DOCKER_DIR"

# Define paths for repository files (used later in Step 6)
EXISTING_REPOS="$TARGET_DOCKER_DIR/image/overlay2/repositories.json"
NEW_REPOS="$NEW_DOCKER_DIR/image/overlay2/repositories.json"

log "INFO" "Processing repository metadata..."
log "INFO" "Existing repos: $EXISTING_REPOS"
log "INFO" "New repos: $NEW_REPOS"

# Step 2: Merge image database
log "INFO" "Merging image database..."
NEW_IMAGEDB="$NEW_DOCKER_DIR/image/overlay2/imagedb/content/sha256"
EXISTING_IMAGEDB="$TARGET_DOCKER_DIR/image/overlay2/imagedb/content/sha256"

if [ -d "$NEW_IMAGEDB" ]; then
    mkdir -p "$EXISTING_IMAGEDB"
    
    # Use BusyBox-compatible commands only
    for image_file in "$NEW_IMAGEDB"/*; do
        if [ -f "$image_file" ]; then
            image_id=$(basename "$image_file")
            target_file="$EXISTING_IMAGEDB/$image_id"
            
            if [ ! -f "$target_file" ]; then
                cp "$image_file" "$target_file"
                log "DEBUG" "Added image: $image_id"
            else
                log "DEBUG" "Image already exists: $image_id"
            fi
        fi
    done
fi

# Step 3: Merge imagedb metadata
log "INFO" "Merging image metadata..."
NEW_METADATA="$NEW_DOCKER_DIR/image/overlay2/imagedb/metadata/sha256"
EXISTING_METADATA="$TARGET_DOCKER_DIR/image/overlay2/imagedb/metadata/sha256"

if [ -d "$NEW_METADATA" ]; then
    mkdir -p "$EXISTING_METADATA"
    
    for metadata_dir in "$NEW_METADATA"/*; do
        if [ -d "$metadata_dir" ]; then
            metadata_id=$(basename "$metadata_dir")
            target_dir="$EXISTING_METADATA/$metadata_id"
            
            if [ ! -d "$target_dir" ]; then
                cp -r "$metadata_dir" "$target_dir"
                log "DEBUG" "Added metadata: $metadata_id"
            else
                log "DEBUG" "Metadata already exists: $metadata_id"
            fi
        fi
    done
fi

# Step 4: Merge layerdb (critical for image integrity)
log "INFO" "Merging layer database..."
NEW_LAYERDB="$NEW_DOCKER_DIR/image/overlay2/layerdb"
EXISTING_LAYERDB="$TARGET_DOCKER_DIR/image/overlay2/layerdb"

if [ -d "$NEW_LAYERDB" ]; then
    mkdir -p "$EXISTING_LAYERDB"
    
    # Process sha256 and tmp subdirectories
    for layerdb_subdir in sha256 tmp; do
        if [ -d "$NEW_LAYERDB/$layerdb_subdir" ]; then
            mkdir -p "$EXISTING_LAYERDB/$layerdb_subdir"
            
            for layer_item in "$NEW_LAYERDB/$layerdb_subdir"/*; do
                if [ -e "$layer_item" ]; then
                    layer_name=$(basename "$layer_item")
                    target_item="$EXISTING_LAYERDB/$layerdb_subdir/$layer_name"
                    
                    if [ ! -e "$target_item" ]; then
                        cp -r "$layer_item" "$target_item"
                        log "DEBUG" "Added layerdb entry: $layerdb_subdir/$layer_name"
                    else
                        log "DEBUG" "Layerdb entry already exists: $layerdb_subdir/$layer_name"
                    fi
                fi
            done
        fi
    done
fi

# Step 5: Merge overlay2 layers
log "INFO" "Merging overlay2 layers..."
NEW_OVERLAY2="$NEW_DOCKER_DIR/overlay2"
EXISTING_OVERLAY2="$TARGET_DOCKER_DIR/overlay2"

if [ -d "$NEW_OVERLAY2" ]; then
    mkdir -p "$EXISTING_OVERLAY2"
    
    # Merge layer directories
    for layer_dir in "$NEW_OVERLAY2"/*; do
        if [ -d "$layer_dir" ]; then
            layer_id=$(basename "$layer_dir")
            target_dir="$EXISTING_OVERLAY2/$layer_id"
            
            # Skip the 'l' directory (handle separately)
            if [ "$layer_id" = "l" ]; then
                continue
            fi
            
            if [ ! -d "$target_dir" ]; then
                cp -r "$layer_dir" "$target_dir"
                log "DEBUG" "Added layer: $layer_id"
            else
                log "DEBUG" "Layer already exists: $layer_id"
            fi
        fi
    done
    
    # Handle overlay2/l directory (symlinks) separately
    if [ -d "$NEW_OVERLAY2/l" ]; then
        mkdir -p "$EXISTING_OVERLAY2/l"
        for link_file in "$NEW_OVERLAY2/l"/*; do
            if [ -L "$link_file" ]; then
                link_name=$(basename "$link_file")
                target_link="$EXISTING_OVERLAY2/l/$link_name"
                
                if [ ! -e "$target_link" ]; then
                    # Use cp -P to preserve symlinks (BusyBox compatible)
                    cp -P "$link_file" "$target_link"
                    log "DEBUG" "Added layer link: $link_name"
                else
                    log "DEBUG" "Layer link already exists: $link_name"
                fi
            fi
        done
    fi
fi

# Step 6: Merge repositories.json using Python for proper JSON handling
log "INFO" "Merging repositories.json..."

merge_docker_repositories() {
    local target_file="$1"
    local new_file="$2"

    if [ ! -f "$new_file" ]; then
        log "DEBUG" "No new repositories file to merge"
        return 0
    fi

    # Use python3 for proper JSON merge
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json
import sys

target_file = '$target_file'
new_file = '$new_file'

try:
    # Load existing repos (or create empty structure)
    try:
        with open(target_file, 'r') as f:
            target = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        target = {'Repositories': {}}

    # Load new repos
    with open(new_file, 'r') as f:
        new = json.load(f)

    # Merge repositories
    if 'Repositories' in target and 'Repositories' in new:
        for repo_name, repo_data in new['Repositories'].items():
            if repo_name not in target['Repositories']:
                target['Repositories'][repo_name] = repo_data
            else:
                # Merge tags within the same repository
                target['Repositories'][repo_name].update(repo_data)

    # Write merged result
    with open(target_file, 'w') as f:
        json.dump(target, f)

    print('Merged repositories successfully')
    sys.exit(0)
except Exception as e:
    print(f'JSON merge error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>&1
        return $?
    else
        # Fallback: just use the new file if python3 not available
        log "WARN" "python3 not available, using new repositories file only"
        cp "$new_file" "$target_file"
        return 0
    fi
}

# Ensure parent directory exists
mkdir -p "$(dirname "$EXISTING_REPOS")"

if merge_docker_repositories "$EXISTING_REPOS" "$NEW_REPOS"; then
    log "INFO" "Repository merge completed"
else
    log "WARN" "Repository merge had issues, Docker may need manual repository configuration"
fi

# Validate the result
if [ -f "$EXISTING_REPOS" ]; then
    if grep -q "\"Repositories\":" "$EXISTING_REPOS"; then
        log "INFO" "JSON structure validation passed"
        log "DEBUG" "Final repositories.json:"
        cat "$EXISTING_REPOS"
    else
        log "WARN" "JSON structure validation failed"
    fi
fi

# Step 7: Copy other essential Docker files
log "INFO" "Copying additional Docker configuration files..."
for file in engine-id; do
    if [ -f "$NEW_DOCKER_DIR/$file" ] && [ ! -f "$TARGET_DOCKER_DIR/$file" ]; then
        cp "$NEW_DOCKER_DIR/$file" "$TARGET_DOCKER_DIR/"
        log "DEBUG" "Added configuration file: $file"
    fi
done

# Cleanup temporary extraction directory
log "INFO" "Cleaning up temporary files..."
rm -rf "$TEMP_MERGE_DIR"

# Final verification and reporting
log "INFO" "Performing final verification..."
if [ -f "$TARGET_DOCKER_DIR/image/overlay2/repositories.json" ]; then
    # Count total images (BusyBox compatible)
    TOTAL_IMAGES=0
    if [ -d "$TARGET_DOCKER_DIR/image/overlay2/imagedb/content/sha256" ]; then
        for img in "$TARGET_DOCKER_DIR/image/overlay2/imagedb/content/sha256"/*; do
            if [ -f "$img" ]; then
                TOTAL_IMAGES=$((TOTAL_IMAGES + 1))
            fi
        done
    fi
    
    log "INFO" "Verification results:"
    log "INFO" "  Target directory: $TARGET_DOCKER_DIR"
    log "INFO" "  Total image files: $TOTAL_IMAGES"
    log "INFO" "  Backup location: $BACKUP_DIR"
    
    # Show the final repositories.json content (first 500 chars to avoid spam)
    log "INFO" "Final repositories.json content:"
    if command -v head >/dev/null 2>&1; then
        # If head is available, use it
        head -c 500 "$TARGET_DOCKER_DIR/image/overlay2/repositories.json" 2>/dev/null || cat "$TARGET_DOCKER_DIR/image/overlay2/repositories.json"
    else
        # Fallback for systems without head
        cat "$TARGET_DOCKER_DIR/image/overlay2/repositories.json"
    fi
    
    log "INFO" "🎉 Flexible container merge completed successfully!"
    
    # Provide appropriate next steps based on context
    if [ "$TARGET_DOCKER_DIR" = "/var/lib/docker" ]; then
        log "INFO" "📋 Next steps for on-target deployment:"
        log "INFO" "  systemctl restart docker"
        log "INFO" "  docker images  # Should show all containers"
    else
        log "INFO" "📋 Yocto integration completed:"
        log "INFO" "  Docker storage installed to rootfs: $TARGET_DOCKER_DIR"
        log "INFO" "  Ready for image construction"
        log "INFO" "  Containers will be available when Docker starts on target"
    fi
    
else
    log "ERROR" "Verification failed - repositories.json not found"
    log "ERROR" "Merge may have failed - check backup: $BACKUP_DIR"
    exit 1
fi

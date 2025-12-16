#!/bin/sh
# podman-storage-merger.sh
# Podman containers-storage merger supporting custom target directories
# Maintains backward compatibility with BusyBox for embedded systems

set -e

NEW_STORAGE_TAR="$1"
TARGET_STORAGE_DIR="$2"

# Default to standard Podman location if no target specified
if [ -z "$TARGET_STORAGE_DIR" ]; then
    # Try to detect user's default Podman storage
    if [ -n "$XDG_DATA_HOME" ]; then
        TARGET_STORAGE_DIR="$XDG_DATA_HOME/containers/storage"
    elif [ -d "$HOME/.local/share/containers/storage" ]; then
        TARGET_STORAGE_DIR="$HOME/.local/share/containers/storage"
    else
        TARGET_STORAGE_DIR="/var/lib/containers/storage"
    fi
fi

# Derive backup directory location based on target
TARGET_PARENT=$(dirname "$TARGET_STORAGE_DIR")
BACKUP_DIR="$TARGET_PARENT/containers-backup-$(date +%s)"
TEMP_MERGE_DIR="/tmp/podman-merge-$(date +%s)"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
}

# Safe cleanup function that handles container filesystem permissions
safe_cleanup() {
    local dir_to_cleanup="$1"
    if [ -d "$dir_to_cleanup" ]; then
        rm -rf "$dir_to_cleanup" 2>/dev/null || {
            # Handle permission issues with container filesystems
            log "DEBUG" "Standard cleanup failed for $dir_to_cleanup, using chmod approach..."
            find "$dir_to_cleanup" -type d -exec chmod 755 {} \; 2>/dev/null || true
            find "$dir_to_cleanup" -type f -exec chmod 644 {} \; 2>/dev/null || true
            rm -rf "$dir_to_cleanup" 2>/dev/null || {
                log "WARN" "Could not cleanup temporary directory: $dir_to_cleanup"
                log "WARN" "Manual cleanup may be required: sudo rm -rf $dir_to_cleanup"
            }
        }
    fi
}

show_usage() {
    echo "Usage: $0 <new-containers-storage.tar> [target-storage-directory]"
    echo ""
    echo "Examples:"
    echo "  # Standard rootless installation:"
    echo "  $0 containers-storage.tar"
    echo "  # -> Installs to ~/.local/share/containers/storage"
    echo ""
    echo "  # System installation:"
    echo "  $0 containers-storage.tar /var/lib/containers/storage"
    echo "  # -> Installs to /var/lib/containers/storage"
    echo ""
    echo "  # Yocto rootfs integration:"
    echo "  $0 containers-storage.tar /path/to/rootfs/var/lib/containers/storage"
    echo "  # -> Installs to custom rootfs path"
    echo ""
    echo "Features:"
    echo "  - Automatic fresh vs additive detection"
    echo "  - BusyBox compatible commands only"
    echo "  - Safe backup creation before merging"
    echo "  - Podman containers-storage structure preservation"
    echo "  - Cross-architecture container support"
    echo "  - Safe cleanup with permission handling"
}

if [ -z "$NEW_STORAGE_TAR" ]; then
    show_usage
    exit 1
fi

if [ ! -f "$NEW_STORAGE_TAR" ]; then
    log "ERROR" "Storage file not found: $NEW_STORAGE_TAR"
    exit 1
fi

log "INFO" "Starting Podman containers-storage merge"
log "INFO" "New storage: $NEW_STORAGE_TAR"
log "INFO" "Target directory: $TARGET_STORAGE_DIR"
log "INFO" "Backup location: $BACKUP_DIR"

# Create target directory parent if it doesn't exist (for Yocto integration)
TARGET_PARENT_DIR=$(dirname "$TARGET_STORAGE_DIR")
if [ ! -d "$TARGET_PARENT_DIR" ]; then
    log "INFO" "Creating target parent directory: $TARGET_PARENT_DIR"
    mkdir -p "$TARGET_PARENT_DIR"
fi

# Check if this is fresh or additive installation
FRESH_INSTALL=false
if [ ! -d "$TARGET_STORAGE_DIR" ] || [ ! "$(ls -A "$TARGET_STORAGE_DIR" 2>/dev/null)" ]; then
    FRESH_INSTALL=true
    log "INFO" "Fresh installation detected - extracting directly"
    
    # Create target parent if needed (for Yocto)
    mkdir -p "$TARGET_PARENT_DIR"
    
    # Extract storage archive
    # First check what's in the archive to understand structure
    ARCHIVE_CONTENTS=$(tar -tf "$NEW_STORAGE_TAR" | head -10)
    log "DEBUG" "Archive contents preview:"
    echo "$ARCHIVE_CONTENTS" | while read line; do
        log "DEBUG" "  $line"
    done
    
    # Determine extraction method based on archive structure
    FIRST_ENTRY=$(tar -tf "$NEW_STORAGE_TAR" | head -1)
    if echo "$FIRST_ENTRY" | grep -q "^[^/]*/"; then
        # Archive contains a top-level directory (e.g., "podman-storage-123/")
        log "DEBUG" "Archive contains top-level directory, extracting and moving"
        
        # Extract to temporary location first
        TEMP_EXTRACT_DIR="/tmp/podman-extract-$(date +%s)"
        mkdir -p "$TEMP_EXTRACT_DIR"
        tar --no-same-owner -xf "$NEW_STORAGE_TAR" -C "$TEMP_EXTRACT_DIR"
        
        # Find the extracted directory
        EXTRACTED_DIR=$(find "$TEMP_EXTRACT_DIR" -maxdepth 1 -type d ! -path "$TEMP_EXTRACT_DIR" | head -1)
        if [ -n "$EXTRACTED_DIR" ] && [ -d "$EXTRACTED_DIR" ]; then
            # Move the contents to target location
            mkdir -p "$TARGET_STORAGE_DIR"
            cp -r "$EXTRACTED_DIR"/* "$TARGET_STORAGE_DIR/"
            log "INFO" "Moved extracted storage to: $TARGET_STORAGE_DIR"
        else
            log "ERROR" "Failed to find extracted storage directory"
            safe_cleanup "$TEMP_EXTRACT_DIR"
            exit 1
        fi
        
        # Safe cleanup of temporary extraction
        safe_cleanup "$TEMP_EXTRACT_DIR"
        
    else
        # Archive contains storage files directly at root level
        log "DEBUG" "Archive contains storage files at root, extracting directly"
        mkdir -p "$TARGET_STORAGE_DIR"
        tar --no-same-owner -xf "$NEW_STORAGE_TAR" -C "$TARGET_STORAGE_DIR"
    fi
    
    # Verify extraction created expected structure
    if [ ! -d "$TARGET_STORAGE_DIR" ]; then
        log "ERROR" "Extraction did not create expected storage directory"
        log "ERROR" "Expected: $TARGET_STORAGE_DIR"
        exit 1
    fi
    
    # Check for typical containers-storage structure (overlay or vfs driver)
    STORAGE_VALID=false
    STORAGE_DRIVER="unknown"
    for check_dir in overlay overlay-containers overlay-images overlay-layers; do
        if [ -d "$TARGET_STORAGE_DIR/$check_dir" ]; then
            STORAGE_VALID=true
            STORAGE_DRIVER="overlay"
            break
        fi
    done
    # Check for vfs driver structure if overlay not found
    if [ "$STORAGE_VALID" = "false" ]; then
        for check_dir in vfs vfs-containers vfs-images vfs-layers; do
            if [ -d "$TARGET_STORAGE_DIR/$check_dir" ]; then
                STORAGE_VALID=true
                STORAGE_DRIVER="vfs"
                break
            fi
        done
    fi

    if [ "$STORAGE_VALID" = "false" ]; then
        log "WARN" "Storage structure may be incomplete - no standard storage directories found"
        log "INFO" "This may be normal for empty storage or different Podman versions"
    else
        log "INFO" "Detected storage driver: $STORAGE_DRIVER"
    fi

    # Remove libpod runtime state files - these should be recreated by target Podman
    # db.sql is the libpod database (container runtime state), not image storage
    if [ -f "$TARGET_STORAGE_DIR/db.sql" ]; then
        log "DEBUG" "Removing stale libpod database (db.sql)"
        rm -f "$TARGET_STORAGE_DIR/db.sql"
    fi
    if [ -d "$TARGET_STORAGE_DIR/libpod" ]; then
        log "DEBUG" "Clearing libpod runtime directory"
        rm -rf "$TARGET_STORAGE_DIR/libpod"/*
    fi

    log "INFO" "Fresh installation completed successfully"
    log "INFO" "Containers-storage installed to: $TARGET_STORAGE_DIR"

    # Show what was installed (check both overlay and vfs paths)
    IMAGE_COUNT=0
    if [ -d "$TARGET_STORAGE_DIR/overlay-images" ]; then
        IMAGE_COUNT=$(find "$TARGET_STORAGE_DIR/overlay-images" -type d 2>/dev/null | wc -l)
        IMAGE_COUNT=$((IMAGE_COUNT - 1))
    elif [ -d "$TARGET_STORAGE_DIR/vfs-images" ]; then
        IMAGE_COUNT=$(find "$TARGET_STORAGE_DIR/vfs-images" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    fi
    if [ "$IMAGE_COUNT" -gt 0 ]; then
        log "INFO" "Images installed: $IMAGE_COUNT"
    fi
    
    exit 0
fi

# Additive installation - create backup first
log "INFO" "Additive installation - creating backup of existing storage..."
mkdir -p "$BACKUP_DIR"
cp -r "$TARGET_STORAGE_DIR" "$BACKUP_DIR/"
log "INFO" "Backup created: $BACKUP_DIR"

# Extract new storage to temporary location
log "INFO" "Extracting new storage to temporary location..."
mkdir -p "$TEMP_MERGE_DIR"

# Handle different archive structures (same logic as fresh install)
FIRST_ENTRY=$(tar -tf "$NEW_STORAGE_TAR" | head -1)
if echo "$FIRST_ENTRY" | grep -q "^[^/]*/"; then
    # Archive contains top-level directory
    tar --no-same-owner -xf "$NEW_STORAGE_TAR" -C "$TEMP_MERGE_DIR"
    EXTRACTED_SUBDIR=$(find "$TEMP_MERGE_DIR" -maxdepth 1 -type d ! -path "$TEMP_MERGE_DIR" | head -1)
    if [ -n "$EXTRACTED_SUBDIR" ] && [ -d "$EXTRACTED_SUBDIR" ]; then
        NEW_STORAGE_DIR="$EXTRACTED_SUBDIR"
    else
        log "ERROR" "Failed to find extracted storage in archive"
        safe_cleanup "$TEMP_MERGE_DIR"
        exit 1
    fi
else
    # Archive contains storage files at root
    NEW_STORAGE_DIR="$TEMP_MERGE_DIR"
    tar --no-same-owner -xf "$NEW_STORAGE_TAR" -C "$NEW_STORAGE_DIR"
fi

log "INFO" "New storage extracted to: $NEW_STORAGE_DIR"

# Merge storage components
log "INFO" "Merging containers-storage components..."

# Merge JSON arrays (for images.json, layers.json, containers.json)
merge_json_arrays() {
    local target_file="$1"
    local new_file="$2"

    if [ ! -f "$target_file" ] || [ ! -f "$new_file" ]; then
        return 1
    fi

    # Use python3 if available for proper JSON merge
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json
import sys

try:
    with open('$target_file', 'r') as f:
        target = json.load(f)
    with open('$new_file', 'r') as f:
        new = json.load(f)

    if isinstance(target, list) and isinstance(new, list):
        # Get existing IDs to avoid duplicates
        existing_ids = {item.get('id') for item in target if isinstance(item, dict)}
        # Add new items that don't already exist
        for item in new:
            if isinstance(item, dict) and item.get('id') not in existing_ids:
                target.append(item)

        with open('$target_file', 'w') as f:
            json.dump(target, f)
        sys.exit(0)
    else:
        sys.exit(1)
except Exception as e:
    print(f'JSON merge error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null
        return $?
    else
        # Fallback: just use the new file (overwrites)
        log "WARN" "python3 not available, cannot merge JSON - using new file"
        cp "$new_file" "$target_file"
        return 0
    fi
}

# Merge overlay storage layers
merge_overlay_storage() {
    local component="$1" # overlay, overlay-containers, overlay-images, overlay-layers, vfs, etc.

    log "DEBUG" "Merging $component storage..."

    if [ -d "$NEW_STORAGE_DIR/$component" ]; then
        mkdir -p "$TARGET_STORAGE_DIR/$component"

        # Copy all items from new storage to target
        for item in "$NEW_STORAGE_DIR/$component"/*; do
            if [ -e "$item" ]; then
                item_name=$(basename "$item")
                target_item="$TARGET_STORAGE_DIR/$component/$item_name"

                if [ ! -e "$target_item" ]; then
                    if [ -d "$item" ]; then
                        cp -r "$item" "$target_item"
                    else
                        cp "$item" "$target_item"
                    fi
                    log "DEBUG" "Added $component entry: $item_name"
                else
                    # Handle JSON array files that need merging
                    case "$item_name" in
                        images.json|layers.json|containers.json)
                            if merge_json_arrays "$target_item" "$item"; then
                                log "DEBUG" "Merged $component JSON: $item_name"
                            else
                                log "DEBUG" "$component JSON merge failed, keeping existing: $item_name"
                            fi
                            ;;
                        *)
                            # For directories, recursively merge subdirectories
                            # This handles vfs/dir/<layer-id> directories
                            if [ -d "$item" ]; then
                                log "DEBUG" "Recursively merging $component/$item_name..."
                                for subitem in "$item"/*; do
                                    if [ -e "$subitem" ]; then
                                        subitem_name=$(basename "$subitem")
                                        target_subitem="$target_item/$subitem_name"
                                        if [ ! -e "$target_subitem" ]; then
                                            if [ -d "$subitem" ]; then
                                                cp -r "$subitem" "$target_subitem"
                                            else
                                                cp "$subitem" "$target_subitem"
                                            fi
                                            log "DEBUG" "Added nested $component/$item_name entry: $subitem_name"
                                        fi
                                    fi
                                done
                            else
                                log "DEBUG" "$component entry already exists: $item_name"
                            fi
                            ;;
                    esac
                fi
            fi
        done
    fi
}

# Merge each storage component (support both overlay and vfs drivers)
for component in overlay overlay-containers overlay-images overlay-layers vfs vfs-containers vfs-images vfs-layers cache libpod; do
    merge_overlay_storage "$component"
done

# Merge configuration files
log "INFO" "Merging configuration files..."
for config_file in storage.conf mounts.conf; do
    if [ -f "$NEW_STORAGE_DIR/$config_file" ]; then
        target_config="$TARGET_STORAGE_DIR/$config_file"
        
        if [ ! -f "$target_config" ]; then
            cp "$NEW_STORAGE_DIR/$config_file" "$target_config"
            log "DEBUG" "Added configuration: $config_file"
        else
            # For config files, use the new one but backup the old
            cp "$target_config" "$target_config.backup.$(date +%s)"
            cp "$NEW_STORAGE_DIR/$config_file" "$target_config"
            log "DEBUG" "Updated configuration: $config_file (backup created)"
        fi
    fi
done

# Handle any additional files in storage root
log "INFO" "Merging additional storage files..."
for item in "$NEW_STORAGE_DIR"/*; do
    if [ -f "$item" ]; then
        item_name=$(basename "$item")
        
        # Skip already handled config files
        case "$item_name" in
            storage.conf|mounts.conf)
                continue
                ;;
        esac
        
        target_item="$TARGET_STORAGE_DIR/$item_name"
        if [ ! -f "$target_item" ]; then
            cp "$item" "$target_item"
            log "DEBUG" "Added storage file: $item_name"
        fi
    fi
done

# Cleanup temporary merge directory with safe cleanup
log "INFO" "Cleaning up temporary files..."
safe_cleanup "$TEMP_MERGE_DIR"

# Final verification and reporting
log "INFO" "Performing final verification..."

# Count images and containers (support both overlay and vfs drivers)
IMAGE_COUNT=0
CONTAINER_COUNT=0

if [ -d "$TARGET_STORAGE_DIR/overlay-images" ]; then
    IMAGE_COUNT=$(find "$TARGET_STORAGE_DIR/overlay-images" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
elif [ -d "$TARGET_STORAGE_DIR/vfs-images" ]; then
    IMAGE_COUNT=$(find "$TARGET_STORAGE_DIR/vfs-images" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
fi

if [ -d "$TARGET_STORAGE_DIR/overlay-containers" ]; then
    CONTAINER_COUNT=$(find "$TARGET_STORAGE_DIR/overlay-containers" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
elif [ -d "$TARGET_STORAGE_DIR/vfs-containers" ]; then
    CONTAINER_COUNT=$(find "$TARGET_STORAGE_DIR/vfs-containers" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
fi

log "INFO" "Verification results:"
log "INFO" "  Target directory: $TARGET_STORAGE_DIR"
log "INFO" "  Images: $IMAGE_COUNT"
log "INFO" "  Containers: $CONTAINER_COUNT"
log "INFO" "  Backup location: $BACKUP_DIR"

# Show storage configuration if available
if [ -f "$TARGET_STORAGE_DIR/storage.conf" ]; then
    log "INFO" "Storage configuration:"
    
    # Extract key configuration values (BusyBox compatible)
    DRIVER=$(grep "driver.*=" "$TARGET_STORAGE_DIR/storage.conf" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' "' || echo "unknown")
    GRAPHROOT=$(grep "graphroot.*=" "$TARGET_STORAGE_DIR/storage.conf" 2>/dev/null | head -1 | cut -d= -f2 | tr -d ' "' || echo "unknown")
    
    log "INFO" "  Driver: $DRIVER"
    log "INFO" "  Graph root: $GRAPHROOT"
fi

# Final cleanup: Remove libpod runtime state files after merge
# These are session-specific and should be recreated by target Podman
if [ -f "$TARGET_STORAGE_DIR/db.sql" ]; then
    log "DEBUG" "Removing stale libpod database (db.sql) after merge"
    rm -f "$TARGET_STORAGE_DIR/db.sql"
fi
if [ -d "$TARGET_STORAGE_DIR/libpod" ]; then
    log "DEBUG" "Clearing libpod runtime directory after merge"
    rm -rf "$TARGET_STORAGE_DIR/libpod"/* 2>/dev/null || true
fi

log "INFO" "🎉 Podman containers-storage merge completed successfully!"

# Provide appropriate next steps based on context
if echo "$TARGET_STORAGE_DIR" | grep -q "^$HOME" || echo "$TARGET_STORAGE_DIR" | grep -q "/.local/share/containers"; then
    log "INFO" "📋 Next steps for rootless deployment:"
    log "INFO" "  podman images  # Should show all containers"
    log "INFO" "  podman run <image>  # Run containers"
elif [ "$TARGET_STORAGE_DIR" = "/var/lib/containers/storage" ]; then
    log "INFO" "📋 Next steps for system deployment:"
    log "INFO" "  sudo podman images  # Should show all containers"
    log "INFO" "  sudo podman run <image>  # Run containers"
else
    log "INFO" "📋 Yocto integration completed:"
    log "INFO" "  Containers-storage installed to rootfs: $TARGET_STORAGE_DIR"
    log "INFO" "  Ready for image construction"
    log "INFO" "  Containers will be available when Podman starts on target"
fi

# Check if Podman is available for immediate verification
if command -v podman >/dev/null 2>&1; then
    log "INFO" ""
    log "INFO" "🔍 Quick verification (if storage is in current user's path):"
    if echo "$TARGET_STORAGE_DIR" | grep -q "^$HOME" || echo "$TARGET_STORAGE_DIR" | grep -q "/.local/share/containers"; then
        log "INFO" "  Run: podman images"
    else
        log "INFO" "  Run: sudo podman images"
        log "INFO" "  Or configure CONTAINERS_STORAGE_CONF to point to: $TARGET_STORAGE_DIR"
    fi
else
    log "INFO" ""
    log "INFO" "💡 Install Podman to verify container availability"
fi

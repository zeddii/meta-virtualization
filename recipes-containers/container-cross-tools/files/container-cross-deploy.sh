#!/bin/bash
# container-cross-deploy: Unified container deployment supporting Docker + Podman runtimes
# Primary interface for cross-architecture container processing with intelligent runtime selection
# Supports both legacy (base64 console) and virtio-9p I/O modes

set -e

VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    case "$level" in
        "INFO")
            echo -e "${GREEN}[$timestamp] [INFO] $message${NC}"
            ;;
        "WARN")
            echo -e "${YELLOW}[$timestamp] [WARN] $message${NC}" >&2
            ;;
        "ERROR")
            echo -e "${RED}[$timestamp] [ERROR] $message${NC}" >&2
            ;;
        "DEBUG")
            if [ "${VERBOSE:-false}" = "true" ]; then
                echo -e "${BLUE}[$timestamp] [DEBUG] $message${NC}"
            fi
            ;;
        "SUCCESS")
            echo -e "${GREEN}[$timestamp] [SUCCESS] $message${NC}"
            ;;
    esac
}

show_usage() {
    cat << EOF
${BOLD}container-cross-deploy${NC} v${VERSION}
Unified container deployment supporting Docker + Podman runtimes

${BOLD}USAGE:${NC}
    container-cross-deploy [OPTIONS] <runtime> <container-path> <target-directory> [additional-args...]

${BOLD}RUNTIME OPTIONS:${NC}
    ${CYAN}docker${NC}        Use Docker runtime (QEMU-based processing)
    ${CYAN}podman${NC}        Use Podman runtime (Skopeo fast path + QEMU fallback)

${BOLD}GLOBAL OPTIONS:${NC}
    --work-dir <path>         Working directory for temporary files
    --arch <arch>             Target architecture (aarch64, arm, x86_64)
    --rootfs <path>           Rootfs directory for QEMU processing (legacy mode)
    --kernel <path>           Kernel image for QEMU processing
    --initramfs <path>        Pre-built initramfs (enables Phase 2 mode, no --rootfs needed)
    --use-9p                  Use virtio-9p for I/O (blocked - kernel lacks 9p support)
    --use-blk                 Use virtio-blk for I/O (default for Docker, fast and reliable)
    --verbose, -v             Enable verbose logging
    --help, -h                Show this help message

${BOLD}I/O MODES:${NC}
    ${CYAN}virtio-blk (default)${NC}  Virtio-blk input + base64 output (fast, reliable)
    ${CYAN}Legacy${NC}               Container embedded in initramfs, base64 console transfer
    ${CYAN}--use-9p${NC}             Virtio-9p I/O (blocked - kernel lacks support)
    ${CYAN}--initramfs${NC}          Pre-built initramfs blob (Phase 2)

${BOLD}DOCKER RUNTIME ARGUMENTS:${NC}
    container-path           Path to OCI container directory or Docker tar file
    target-directory         Target Docker storage directory (e.g., /var/lib/docker)
    rootfs-dir              Rootfs directory for QEMU processing
    kernel-image            Kernel image for QEMU processing
    [container-name]        Optional container name

${BOLD}PODMAN RUNTIME ARGUMENTS:${NC}
    container-path           Path to OCI container directory or Docker tar file  
    target-directory         Target containers-storage directory (e.g., /var/lib/containers/storage)
    [rootfs-dir]            Rootfs directory (for QEMU fallback)
    [kernel-image]          Kernel image (for QEMU fallback)

${BOLD}EXAMPLES:${NC}
    # Podman deployment (recommended - 14x faster with Skopeo)
    container-cross-deploy podman ./app-container/ /var/lib/containers/storage

    # Docker deployment (reliable QEMU-based)
    container-cross-deploy docker ./app-container/ /var/lib/docker ./rootfs/ ./Image

    # Yocto integration with custom work directory
    container-cross-deploy --work-dir /tmp/yocto-work podman ./app-oci/ /path/to/rootfs/var/lib/containers/storage

    # Docker with custom work directory and verbose logging
    container-cross-deploy -v --work-dir /tmp/build-work docker ./app/ /var/lib/docker ./rootfs/ ./Image

${BOLD}PERFORMANCE COMPARISON:${NC}
    Podman (Skopeo):     ~5 seconds    (14x faster, recommended)
    Docker (QEMU):       ~71 seconds   (legacy base64 transfer)
    Docker (9p):         ~30 seconds   (virtio-9p, faster I/O)
    Podman (QEMU):       ~60-90s       (fallback when Skopeo fails)

${BOLD}BACKEND SCRIPTS:${NC}
    Docker (virtio-blk): docker-storage-creator-blk.sh + flexible-container-merger.sh
    Docker (legacy):     docker-storage-creator-cached.sh + flexible-container-merger.sh
    Docker (9p):         docker-storage-creator-9p.sh + flexible-container-merger.sh (blocked)
    Podman processing:   podman-storage-creator.sh + podman-storage-merger.sh

EOF
}

# Find backend scripts
find_backend_script() {
    local script_name="$1"
    local script_path=""
    
    # Check in same directory as this script
    if [ -f "$SCRIPT_DIR/$script_name" ]; then
        script_path="$SCRIPT_DIR/$script_name"
    # Check in PATH
    elif command -v "$script_name" >/dev/null 2>&1; then
        script_path=$(command -v "$script_name")
    # Check common locations
    elif [ -f "/usr/local/bin/$script_name" ]; then
        script_path="/usr/local/bin/$script_name"
    elif [ -f "/usr/bin/$script_name" ]; then
        script_path="/usr/bin/$script_name"
    fi
    
    echo "$script_path"
}

# Validate environment and find required scripts
validate_environment() {
    local runtime="$1"
    local errors=0
    
    case "$runtime" in
        "docker")
            DOCKER_CREATOR=$(find_backend_script "docker-storage-creator-cached.sh")
            DOCKER_CREATOR_9P=$(find_backend_script "docker-storage-creator-9p.sh")
            DOCKER_CREATOR_BLK=$(find_backend_script "docker-storage-creator-blk.sh")
            DOCKER_MERGER=$(find_backend_script "flexible-container-merger.sh")

            # virtio-blk creator is now the default
            if [ -z "$DOCKER_CREATOR_BLK" ]; then
                log "WARN" "Docker virtio-blk creator not found: docker-storage-creator-blk.sh"
                log "WARN" "Will fall back to legacy mode"
            else
                log "DEBUG" "Found Docker creator (virtio-blk): $DOCKER_CREATOR_BLK"
            fi

            if [ -z "$DOCKER_CREATOR" ]; then
                log "DEBUG" "Docker legacy creator not found (optional): docker-storage-creator-cached.sh"
            else
                log "DEBUG" "Found Docker creator (legacy): $DOCKER_CREATOR"
            fi

            if [ -z "$DOCKER_CREATOR_9P" ]; then
                log "DEBUG" "Docker 9p creator not found (optional): docker-storage-creator-9p.sh"
            else
                log "DEBUG" "Found Docker creator (9p): $DOCKER_CREATOR_9P"
            fi

            # Need at least one creator
            if [ -z "$DOCKER_CREATOR_BLK" ] && [ -z "$DOCKER_CREATOR" ]; then
                log "ERROR" "No Docker creator script found (need docker-storage-creator-blk.sh or docker-storage-creator-cached.sh)"
                errors=$((errors + 1))
            fi

            if [ -z "$DOCKER_MERGER" ]; then
                log "ERROR" "Docker merger script not found: flexible-container-merger.sh"
                errors=$((errors + 1))
            else
                log "DEBUG" "Found Docker merger: $DOCKER_MERGER"
            fi
            ;;
            
        "podman")
            PODMAN_CREATOR=$(find_backend_script "podman-storage-creator.sh")
            PODMAN_MERGER=$(find_backend_script "podman-storage-merger.sh")
            
            if [ -z "$PODMAN_CREATOR" ]; then
                log "ERROR" "Podman creator script not found: podman-storage-creator.sh"
                errors=$((errors + 1))
            else
                log "DEBUG" "Found Podman creator: $PODMAN_CREATOR"
            fi
            
            if [ -z "$PODMAN_MERGER" ]; then
                log "ERROR" "Podman merger script not found: podman-storage-merger.sh"
                errors=$((errors + 1))
            else
                log "DEBUG" "Found Podman merger: $PODMAN_MERGER"
            fi
            ;;
            
        *)
            log "ERROR" "Unknown runtime: $runtime"
            errors=$((errors + 1))
            ;;
    esac
    
    return $errors
}

# Parse command line arguments
parse_arguments() {
    RUNTIME=""
    WORK_DIR=""
    TARGET_ARCH=""
    ROOTFS_DIR=""
    KERNEL_IMAGE=""
    INITRAMFS_IMAGE=""
    USE_9P="false"
    USE_BLK="auto"  # auto = use virtio-blk if available, otherwise legacy
    USE_LEGACY="false"
    VERBOSE="false"
    POSITIONAL_ARGS=()

    while [ $# -gt 0 ]; do
        case $1 in
            --work-dir)
                WORK_DIR="$2"
                shift 2
                ;;
            --arch)
                TARGET_ARCH="$2"
                shift 2
                ;;
            --rootfs)
                ROOTFS_DIR="$2"
                shift 2
                ;;
            --kernel)
                KERNEL_IMAGE="$2"
                shift 2
                ;;
            --initramfs)
                INITRAMFS_IMAGE="$2"
                USE_9P="true"  # --initramfs implies 9p mode
                shift 2
                ;;
            --use-9p)
                USE_9P="true"
                USE_BLK="false"
                shift
                ;;
            --use-blk)
                USE_BLK="true"
                shift
                ;;
            --use-legacy)
                USE_LEGACY="true"
                USE_BLK="false"
                shift
                ;;
            --verbose|-v)
                VERBOSE="true"
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            --*)
                log "ERROR" "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                POSITIONAL_ARGS+=("$1")
                shift
                ;;
        esac
    done
    
    # Export for backend scripts
    export VERBOSE WORK_DIR
    
    # Extract runtime and remaining arguments
    if [ ${#POSITIONAL_ARGS[@]} -lt 3 ]; then
        log "ERROR" "Insufficient arguments"
        show_usage
        exit 1
    fi
    
    RUNTIME="${POSITIONAL_ARGS[0]}"
    CONTAINER_PATH="${POSITIONAL_ARGS[1]}"
    TARGET_DIRECTORY="${POSITIONAL_ARGS[2]}"
    
    # Additional positional arguments (for cases where not using --options)
    ADDITIONAL_POSITIONAL=("${POSITIONAL_ARGS[@]:3}")
}

# Deploy using Docker runtime
deploy_docker() {
    local container_path="$1"
    local target_directory="$2"

    log "INFO" "🐳 Docker Runtime Selected"
    log "INFO" "Container: $container_path"
    log "INFO" "Target: $target_directory"

    # Use command-line options if provided, otherwise fall back to positional args
    local rootfs_dir="$ROOTFS_DIR"
    local kernel_image="$KERNEL_IMAGE"
    local initramfs_image="$INITRAMFS_IMAGE"
    local target_arch="$TARGET_ARCH"
    local use_9p="$USE_9P"
    local use_blk="$USE_BLK"
    local use_legacy="$USE_LEGACY"
    local container_name=""

    # If not provided via options, try positional arguments
    if [ -z "$rootfs_dir" ] && [ ${#ADDITIONAL_POSITIONAL[@]} -gt 0 ]; then
        rootfs_dir="${ADDITIONAL_POSITIONAL[0]}"
    fi

    if [ -z "$kernel_image" ] && [ ${#ADDITIONAL_POSITIONAL[@]} -gt 1 ]; then
        kernel_image="${ADDITIONAL_POSITIONAL[1]}"
    fi

    if [ -z "$target_arch" ]; then
        target_arch="$(uname -m)"  # Default to current architecture
    fi

    if [ ${#ADDITIONAL_POSITIONAL[@]} -gt 2 ]; then
        container_name="${ADDITIONAL_POSITIONAL[2]}"
    else
        container_name="docker-storage"
    fi

    # Determine which mode we're in
    # Priority: explicit options > auto-detect
    local mode=""
    if [ -n "$initramfs_image" ]; then
        mode="9p-prebuilt"  # Phase 2: pre-built initramfs (blocked)
    elif [ "$use_9p" = "true" ]; then
        mode="9p-dynamic"   # Phase 1: dynamic initramfs with 9p I/O (blocked)
    elif [ "$use_legacy" = "true" ]; then
        mode="legacy"       # Force legacy mode
    elif [ "$use_blk" = "true" ]; then
        mode="virtio-blk"   # Explicit virtio-blk
    elif [ "$use_blk" = "auto" ]; then
        # Auto-detect: prefer virtio-blk if available
        if [ -n "$DOCKER_CREATOR_BLK" ]; then
            mode="virtio-blk"
        else
            mode="legacy"
        fi
    else
        mode="legacy"
    fi

    log "INFO" "I/O Mode: $mode"

    # Validate based on mode
    if [ "$mode" = "9p-prebuilt" ]; then
        # Phase 2: need kernel and initramfs, NOT rootfs
        if [ -z "$kernel_image" ]; then
            log "ERROR" "Phase 2 mode requires --kernel"
            exit 1
        fi
        if [ ! -f "$kernel_image" ]; then
            log "ERROR" "Kernel image not found: $kernel_image"
            exit 1
        fi
        if [ ! -f "$initramfs_image" ]; then
            log "ERROR" "Initramfs not found: $initramfs_image"
            exit 1
        fi
    elif [ "$mode" = "virtio-blk" ]; then
        # Virtio-blk mode: need rootfs and kernel
        if [ -z "$rootfs_dir" ] || [ -z "$kernel_image" ]; then
            log "ERROR" "Docker virtio-blk mode requires rootfs and kernel arguments"
            log "ERROR" "Usage: container-cross-deploy docker <container> <target> --rootfs <rootfs-dir> --kernel <kernel-image>"
            exit 1
        fi
        if [ ! -d "$rootfs_dir" ]; then
            log "ERROR" "Rootfs directory not found: $rootfs_dir"
            exit 1
        fi
        if [ ! -f "$kernel_image" ]; then
            log "ERROR" "Kernel image not found: $kernel_image"
            exit 1
        fi
    else
        # Legacy or Phase 1: need rootfs and kernel
        if [ -z "$rootfs_dir" ] || [ -z "$kernel_image" ]; then
            log "ERROR" "Docker runtime requires rootfs and kernel arguments"
            log "ERROR" "Usage: container-cross-deploy docker <container> <target> --rootfs <rootfs-dir> --kernel <kernel-image>"
            log "ERROR" "   OR: container-cross-deploy docker <container> <target> <rootfs-dir> <kernel-image> [container-name]"
            exit 1
        fi
        if [ ! -d "$rootfs_dir" ]; then
            log "ERROR" "Rootfs directory not found: $rootfs_dir"
            exit 1
        fi
        if [ ! -f "$kernel_image" ]; then
            log "ERROR" "Kernel image not found: $kernel_image"
            exit 1
        fi
    fi

    # Validate container path
    if [ ! -e "$container_path" ]; then
        log "ERROR" "Container path not found: $container_path"
        exit 1
    fi

    log "INFO" "Configuration:"
    log "INFO" "  Architecture: $target_arch"
    log "INFO" "  Mode: $mode"
    [ -n "$rootfs_dir" ] && log "INFO" "  Rootfs: $rootfs_dir"
    log "INFO" "  Kernel: $kernel_image"
    [ -n "$initramfs_image" ] && log "INFO" "  Initramfs: $initramfs_image"
    log "INFO" "  Container name: $container_name"

    # Create temporary storage file
    local temp_storage_file
    if [ -n "$WORK_DIR" ]; then
        mkdir -p "$WORK_DIR"
        temp_storage_file="$WORK_DIR/docker-storage-$$.tar"
    else
        temp_storage_file="/tmp/docker-storage-$$.tar"
    fi

    log "INFO" "Step 1: Creating Docker storage package..."

    # Build creator command based on mode
    local creator_cmd
    if [ "$mode" = "virtio-blk" ]; then
        # Virtio-blk mode (new default)
        if [ -z "$DOCKER_CREATOR_BLK" ]; then
            log "ERROR" "Docker virtio-blk creator not found: docker-storage-creator-blk.sh"
            exit 1
        fi
        creator_cmd=("$DOCKER_CREATOR_BLK")
        creator_cmd+=(--kernel "$kernel_image")
        creator_cmd+=(--rootfs "$rootfs_dir")
        [ "$VERBOSE" = "true" ] && creator_cmd+=(--verbose)
        [ -n "$WORK_DIR" ] && creator_cmd+=(--work-dir "$WORK_DIR")
        creator_cmd+=("$container_path" "$temp_storage_file" "$target_arch")
    elif [ "$mode" = "9p-prebuilt" ] || [ "$mode" = "9p-dynamic" ]; then
        # Use 9p creator (blocked - kernel lacks support)
        if [ -z "$DOCKER_CREATOR_9P" ]; then
            log "ERROR" "Docker 9p creator not found: docker-storage-creator-9p.sh"
            log "ERROR" "9p mode requested but script not available"
            exit 1
        fi
        log "WARN" "9p mode is blocked - kernel lacks CONFIG_NET_9P support"
        log "WARN" "Consider using virtio-blk mode instead (default)"
        creator_cmd=("$DOCKER_CREATOR_9P")
        creator_cmd+=(--kernel "$kernel_image")
        creator_cmd+=(--arch "$target_arch")
        [ -n "$WORK_DIR" ] && creator_cmd+=(--work-dir "$WORK_DIR")

        if [ "$mode" = "9p-prebuilt" ]; then
            creator_cmd+=(--initramfs "$initramfs_image")
        else
            # Phase 1: dynamic initramfs - need to build it from rootfs
            creator_cmd+=(--rootfs "$rootfs_dir")
        fi

        creator_cmd+=("$container_path" "$temp_storage_file" "$target_arch")
    else
        # Legacy mode - use original creator
        if [ -z "$DOCKER_CREATOR" ]; then
            log "ERROR" "Docker legacy creator not found: docker-storage-creator-cached.sh"
            exit 1
        fi
        creator_cmd=("$DOCKER_CREATOR")
        [ -n "$WORK_DIR" ] && creator_cmd+=(--work-dir "$WORK_DIR")
        creator_cmd+=("$container_path" "$temp_storage_file" "$target_arch" "$rootfs_dir" "$kernel_image" "$container_name")
    fi

    log "DEBUG" "Creator command: ${creator_cmd[*]}"

    if "${creator_cmd[@]}"; then
        log "SUCCESS" "Docker storage package created: $temp_storage_file"

        log "INFO" "Step 2: Deploying to target directory..."
        local merger_cmd=("$DOCKER_MERGER" "$temp_storage_file" "$target_directory")
        [ -n "$WORK_DIR" ] && merger_cmd+=("$WORK_DIR")

        if "${merger_cmd[@]}"; then
            log "SUCCESS" "🎉 Docker deployment completed successfully!"
            log "INFO" "Target: $target_directory"
            log "INFO" "Next: systemctl restart docker && docker images"
        else
            log "ERROR" "Docker storage deployment failed"
            exit 1
        fi
        
        # Cleanup temporary file
        rm -f "$temp_storage_file"
    else
        log "ERROR" "Docker storage creation failed"
        exit 1
    fi
}

# Deploy using Podman runtime
deploy_podman() {
    local container_path="$1"
    local target_directory="$2"
    
    log "INFO" "🐙 Podman Runtime Selected (Skopeo Fast Path + QEMU Fallback)"
    log "INFO" "Container: $container_path"
    log "INFO" "Target: $target_directory"
    
    # Podman can work with just container and target, rootfs/kernel optional for fallback
    # Use command-line options if provided, otherwise fall back to positional args
    local rootfs_dir="$ROOTFS_DIR"
    local kernel_image="$KERNEL_IMAGE"
    local target_arch="$TARGET_ARCH"
    
    # If not provided via options, try positional arguments
    if [ -z "$rootfs_dir" ] && [ ${#ADDITIONAL_POSITIONAL[@]} -gt 0 ]; then
        rootfs_dir="${ADDITIONAL_POSITIONAL[0]}"
    fi
    
    if [ -z "$kernel_image" ] && [ ${#ADDITIONAL_POSITIONAL[@]} -gt 1 ]; then
        kernel_image="${ADDITIONAL_POSITIONAL[1]}"
    fi
    
    if [ -z "$target_arch" ]; then
        target_arch="$(uname -m)"  # Default to current architecture
    fi
    
    # Validate inputs
    if [ ! -e "$container_path" ]; then
        log "ERROR" "Container path not found: $container_path"
        exit 1
    fi
    
    log "INFO" "Configuration:"
    log "INFO" "  Architecture: $target_arch"
    log "INFO" "  Rootfs: ${rootfs_dir:-'(optional - for QEMU fallback)'}"
    log "INFO" "  Kernel: ${kernel_image:-'(optional - for QEMU fallback)'}"
    
    # Create temporary storage file
    local temp_storage_file
    if [ -n "$WORK_DIR" ]; then
        mkdir -p "$WORK_DIR"
        temp_storage_file="$WORK_DIR/podman-storage-$$.tar"
    else
        temp_storage_file="/tmp/podman-storage-$$.tar"
    fi
    
    log "INFO" "Step 1: Creating Podman containers-storage package..."
    
    # Build creator command with work directory
    local creator_cmd=("$PODMAN_CREATOR")
    [ -n "$WORK_DIR" ] && creator_cmd+=(--work-dir "$WORK_DIR")
    creator_cmd+=("$container_path" "$temp_storage_file" "$target_arch")
    
    # Add rootfs and kernel if provided (for QEMU fallback)
    [ -n "$rootfs_dir" ] && creator_cmd+=("$rootfs_dir")
    [ -n "$kernel_image" ] && creator_cmd+=("$kernel_image")
    
    log "DEBUG" "Creator command: ${creator_cmd[*]}"
    
    if "${creator_cmd[@]}"; then
        log "SUCCESS" "Podman storage package created: $temp_storage_file"
        
        log "INFO" "Step 2: Deploying to target directory..."
        local merger_cmd=("$PODMAN_MERGER" "$temp_storage_file" "$target_directory")
        [ -n "$WORK_DIR" ] && merger_cmd+=("$WORK_DIR")
        
        if "${merger_cmd[@]}"; then
            log "SUCCESS" "🎉 Podman deployment completed successfully!"
            log "INFO" "Target: $target_directory"
            log "INFO" "Next: podman images"
        else
            log "ERROR" "Podman storage deployment failed"
            exit 1
        fi
        
        # Cleanup temporary file
        rm -f "$temp_storage_file"
    else
        log "ERROR" "Podman storage creation failed"
        exit 1
    fi
}

# Main execution
main() {
    log "INFO" "🚀 Container Cross-Deploy v$VERSION"
    log "INFO" "Unified container deployment supporting Docker + Podman runtimes"
    
    # Parse command line arguments
    parse_arguments "$@"
    
    log "INFO" "📋 Configuration:"
    log "INFO" "  Runtime: $RUNTIME"
    log "INFO" "  Container: $CONTAINER_PATH"
    log "INFO" "  Target: $TARGET_DIRECTORY"
    log "INFO" "  Work directory: ${WORK_DIR:-'(default)'}"
    log "INFO" "  Architecture: ${TARGET_ARCH:-'(auto-detect)'}"
    log "INFO" "  Rootfs: ${ROOTFS_DIR:-'(not specified)'}"
    log "INFO" "  Kernel: ${KERNEL_IMAGE:-'(not specified)'}"
    log "INFO" "  Verbose: $VERBOSE"
    
    # Validate environment and find backend scripts
    if ! validate_environment "$RUNTIME"; then
        log "ERROR" "Environment validation failed"
        exit 1
    fi
    
    # Dispatch to appropriate runtime handler
    case "$RUNTIME" in
        "docker")
            deploy_docker "$CONTAINER_PATH" "$TARGET_DIRECTORY"
            ;;
        "podman")
            deploy_podman "$CONTAINER_PATH" "$TARGET_DIRECTORY"
            ;;
        *)
            log "ERROR" "Unsupported runtime: $RUNTIME"
            show_usage
            exit 1
            ;;
    esac
}

# Execute main function if script is run directly
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi

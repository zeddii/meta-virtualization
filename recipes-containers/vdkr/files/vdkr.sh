#!/bin/bash
# vdkr: Docker-like interface for cross-architecture container operations
#
# This provides a familiar docker-like CLI that executes commands inside
# a QEMU-emulated environment with the target architecture's Docker.
#
# Uses kernel + initramfs from container-cross-install but with a separate
# init script for arbitrary command execution.
#
# Version: 2.3.0
#
# Command naming convention:
#   - Commands matching Docker's syntax/semantics use Docker's name (import, load, save, etc.)
#   - Extended commands with non-Docker behavior use 'v' prefix (vimport)

set -e

VERSION="2.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
# DEFAULT_ARCH is set per-architecture wrapper (vdkr-aarch64, vdkr-x86_64)
# Do not change this line - it is patched by the recipe
DEFAULT_ARCH="${VDKR_ARCH:-aarch64}"
BLOB_DIR="${VDKR_BLOB_DIR:-}"
VERBOSE="${VDKR_VERBOSE:-false}"
STATELESS="${VDKR_STATELESS:-false}"

# Default state directory (per-architecture)
DEFAULT_STATE_DIR="${VDKR_STATE_DIR:-$HOME/.vdkr}"

# Runner script
RUNNER="${VDKR_RUNNER:-$SCRIPT_DIR/vdkr-run.sh}"

# Colors (use $'...' for proper escape interpretation)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

show_usage() {
    local PROG_NAME=$(basename "$0")
    cat << EOF
${BOLD}${PROG_NAME}${NC} v$VERSION - Docker CLI for cross-architecture emulation

${BOLD}USAGE:${NC}
    ${PROG_NAME} [OPTIONS] <command> [args...]

${BOLD}DOCKER-COMPATIBLE COMMANDS:${NC}
    ${CYAN}images${NC}                       List images in emulated Docker
    ${CYAN}load${NC} -i <file>               Load Docker image archive (docker save output)
    ${CYAN}import${NC} <tarball> [name:tag]  Import rootfs tarball as image
    ${CYAN}save${NC} -o <file> <image>       Save image to tar archive
    ${CYAN}tag${NC} <source> <target>        Tag an image
    ${CYAN}rmi${NC} <image>                  Remove an image
    ${CYAN}info${NC}                         Display system info
    ${CYAN}version${NC}                      Show Docker version
    ${CYAN}run${NC} <command>                Run arbitrary docker command

${BOLD}EXTENDED COMMANDS (vdkr-specific):${NC}
    ${CYAN}vimport${NC} <path> [name:tag]    Import from OCI dir, tarball, or directory (auto-detect)
    ${CYAN}vrun${NC} <image> [cmd] [args]    Run a command in a container (non-interactive)
    ${CYAN}clean${NC}                        Remove persistent state (reset to fresh Docker)

${BOLD}OPTIONS:${NC}
    --blob-dir <path>    Path to kernel/initramfs blobs (override default)
    --stateless          Start with fresh Docker state (no persistence)
    --state-dir <path>   Override state directory [default: ~/.vdkr/${DEFAULT_ARCH}]
    --storage <file>     Export docker storage after command (tar file)
    --input-storage <tar> Load Docker state from tar before command
    --verbose, -v        Enable verbose output
    --help, -h           Show this help

${BOLD}EXAMPLES:${NC}
    # List images (uses persistent state by default)
    ${PROG_NAME} images

    # Import rootfs tarball (matches 'docker import' exactly)
    ${PROG_NAME} import rootfs.tar myapp:latest

    # Import OCI directory (extended command, auto-detects format)
    ${PROG_NAME} vimport ./container-oci/ myapp:latest
    ${PROG_NAME} images        # Image persists!

    # Save image to tar archive
    ${PROG_NAME} save -o myapp.tar myapp:latest

    # Load a Docker image archive (from 'docker save')
    ${PROG_NAME} load -i myapp.tar

    # Start fresh (ignore existing state)
    ${PROG_NAME} --stateless images

    # Export storage for deployment to target
    ${PROG_NAME} --storage /tmp/docker-storage.tar vimport ./container-oci/ myapp:latest

    # Run a command in a container (non-interactive)
    ${PROG_NAME} vrun myapp:latest /bin/ls -la /app
    ${PROG_NAME} vrun myapp:latest uname -m    # Check container architecture

    # Run arbitrary docker command
    ${PROG_NAME} run -- docker pull alpine  # (needs networking, may not work)

${BOLD}NOTES:${NC}
    - Architecture: ${DEFAULT_ARCH} (use vdkr-aarch64 or vdkr-x86_64 for other arch)
    - By default, state persists in ~/.vdkr/${DEFAULT_ARCH}/
    - Use --stateless for fresh Docker state each run
    - Use --storage to export Docker storage to tar file
    - Networking is limited inside QEMU (no external pulls)

${BOLD}ENVIRONMENT:${NC}
    VDKR_BLOB_DIR   Path to kernel/initramfs blobs
    VDKR_STATE_DIR  Base directory for state [default: ~/.vdkr]
    VDKR_STATELESS  Run stateless by default (true/false)
    VDKR_VERBOSE    Enable verbose output (true/false)

EOF
}

# Build runner args
build_runner_args() {
    local args=()

    args+=("--arch" "$TARGET_ARCH")

    [ -n "$BLOB_DIR" ] && args+=("--blob-dir" "$BLOB_DIR")
    [ "$VERBOSE" = "true" ] && args+=("--verbose")
    [ -n "$STORAGE_OUTPUT" ] && args+=("--output-type" "storage" "--output" "$STORAGE_OUTPUT")
    [ -n "$STATE_DIR" ] && args+=("--state-dir" "$STATE_DIR")
    [ -n "$INPUT_STORAGE" ] && args+=("--input-storage" "$INPUT_STORAGE")

    echo "${args[@]}"
}

# Parse global options first
TARGET_ARCH="$DEFAULT_ARCH"
STORAGE_OUTPUT=""
STATE_DIR=""
INPUT_STORAGE=""
COMMAND=""
COMMAND_ARGS=()

while [ $# -gt 0 ]; do
    case $1 in
        --blob-dir)
            BLOB_DIR="$2"
            shift 2
            ;;
        --storage)
            STORAGE_OUTPUT="$2"
            shift 2
            ;;
        --state-dir)
            STATE_DIR="$2"
            shift 2
            ;;
        --input-storage)
            INPUT_STORAGE="$2"
            shift 2
            ;;
        --stateless)
            STATELESS="true"
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
        --version)
            echo "vdkr version $VERSION"
            exit 0
            ;;
        -*)
            # Unknown option - might be for subcommand
            COMMAND_ARGS+=("$1")
            shift
            ;;
        *)
            if [ -z "$COMMAND" ]; then
                COMMAND="$1"
            else
                COMMAND_ARGS+=("$1")
            fi
            shift
            ;;
    esac
done

if [ -z "$COMMAND" ]; then
    show_usage
    exit 0
fi

# Set up state directory (default to persistent unless --stateless)
if [ "$STATELESS" != "true" ] && [ -z "$STATE_DIR" ] && [ -z "$INPUT_STORAGE" ]; then
    STATE_DIR="$DEFAULT_STATE_DIR/$TARGET_ARCH"
fi

# Check runner exists
if [ ! -x "$RUNNER" ]; then
    echo -e "${RED}[vdkr]${NC} Runner script not found: $RUNNER" >&2
    exit 1
fi

# Handle commands
case "$COMMAND" in
    images)
        # docker images
        RUNNER_ARGS=$(build_runner_args)
        "$RUNNER" $RUNNER_ARGS -- docker images "${COMMAND_ARGS[@]}"
        ;;

    load)
        # docker load -i <file>
        # Parse -i argument
        INPUT_FILE=""
        LOAD_ARGS=()
        i=0
        while [ $i -lt ${#COMMAND_ARGS[@]} ]; do
            arg="${COMMAND_ARGS[$i]}"
            case "$arg" in
                -i|--input)
                    i=$((i + 1))
                    INPUT_FILE="${COMMAND_ARGS[$i]}"
                    ;;
                *)
                    LOAD_ARGS+=("$arg")
                    ;;
            esac
            i=$((i + 1))
        done

        if [ -z "$INPUT_FILE" ]; then
            echo -e "${RED}[vdkr]${NC} load requires -i <file>" >&2
            exit 1
        fi

        if [ ! -f "$INPUT_FILE" ]; then
            echo -e "${RED}[vdkr]${NC} File not found: $INPUT_FILE" >&2
            exit 1
        fi

        RUNNER_ARGS=$(build_runner_args)
        "$RUNNER" $RUNNER_ARGS --input "$INPUT_FILE" --input-type tar \
            -- "docker load -i {INPUT}/$(basename "$INPUT_FILE") ${LOAD_ARGS[*]}"
        ;;

    import)
        # docker import <tarball> [name:tag] - matches Docker's import exactly
        # Only accepts tarballs (rootfs archives), not OCI directories
        if [ ${#COMMAND_ARGS[@]} -lt 1 ]; then
            echo -e "${RED}[vdkr]${NC} import requires <tarball> [name:tag]" >&2
            echo "For OCI directories, use 'vimport' instead." >&2
            exit 1
        fi

        INPUT_PATH="${COMMAND_ARGS[0]}"
        IMAGE_NAME="${COMMAND_ARGS[1]:-imported:latest}"

        if [ ! -e "$INPUT_PATH" ]; then
            echo -e "${RED}[vdkr]${NC} Not found: $INPUT_PATH" >&2
            exit 1
        fi

        # Only accept files (tarballs), not directories
        if [ -d "$INPUT_PATH" ]; then
            echo -e "${RED}[vdkr]${NC} import only accepts tarballs, not directories" >&2
            echo "For OCI directories, use: vdkr vimport $INPUT_PATH $IMAGE_NAME" >&2
            exit 1
        fi

        RUNNER_ARGS=$(build_runner_args)
        "$RUNNER" $RUNNER_ARGS --input "$INPUT_PATH" --input-type tar \
            -- "docker import {INPUT}/$(basename "$INPUT_PATH") $IMAGE_NAME && docker images"
        ;;

    vimport)
        # Extended import: handles OCI directories, tarballs, and plain directories
        # Auto-detects format
        if [ ${#COMMAND_ARGS[@]} -lt 1 ]; then
            echo -e "${RED}[vdkr]${NC} vimport requires <path> [name:tag]" >&2
            exit 1
        fi

        INPUT_PATH="${COMMAND_ARGS[0]}"
        IMAGE_NAME="${COMMAND_ARGS[1]:-imported:latest}"

        if [ ! -e "$INPUT_PATH" ]; then
            echo -e "${RED}[vdkr]${NC} Not found: $INPUT_PATH" >&2
            exit 1
        fi

        # Detect input type
        if [ -d "$INPUT_PATH" ]; then
            if [ -f "$INPUT_PATH/index.json" ] || [ -f "$INPUT_PATH/oci-layout" ]; then
                INPUT_TYPE="oci"
                # Use skopeo to properly import OCI image with full metadata (entrypoint, cmd, etc.)
                # This preserves the container config unlike raw docker import
                # skopeo to docker-daemon doesn't always set the tag, so tag the latest untagged image
                DOCKER_CMD="skopeo copy oci:{INPUT} docker-daemon:$IMAGE_NAME && IMG_ID=\$(docker images -q | head -n 1) && docker tag \$IMG_ID $IMAGE_NAME && docker images"
            else
                # Directory but not OCI - check if it looks like a deploy/images dir
                # and provide a helpful hint
                if ls "$INPUT_PATH"/*-oci >/dev/null 2>&1; then
                    echo -e "${RED}[vdkr]${NC} Directory is not an OCI container: $INPUT_PATH" >&2
                    echo -e "${YELLOW}[vdkr]${NC} Found OCI directories inside. Did you mean one of these?" >&2
                    for oci_dir in "$INPUT_PATH"/*-oci; do
                        if [ -d "$oci_dir" ]; then
                            echo "    $(basename "$oci_dir")" >&2
                        fi
                    done
                    echo "" >&2
                    echo "Example: vdkr vimport $INPUT_PATH/$(ls "$INPUT_PATH" | grep -m1 '\-oci$') myimage:latest" >&2
                    exit 1
                fi
                INPUT_TYPE="dir"
                DOCKER_CMD="docker import {INPUT} $IMAGE_NAME && docker images"
            fi
        else
            INPUT_TYPE="tar"
            DOCKER_CMD="docker import {INPUT}/$(basename "$INPUT_PATH") $IMAGE_NAME && docker images"
        fi

        RUNNER_ARGS=$(build_runner_args)
        "$RUNNER" $RUNNER_ARGS --input "$INPUT_PATH" --input-type "$INPUT_TYPE" \
            -- "$DOCKER_CMD"
        ;;

    save)
        # docker save -o <file> <image>
        # Requires --state-dir or --input-storage to have existing images
        OUTPUT_FILE=""
        IMAGE_NAME=""
        SAVE_ARGS=()
        i=0
        while [ $i -lt ${#COMMAND_ARGS[@]} ]; do
            arg="${COMMAND_ARGS[$i]}"
            case "$arg" in
                -o|--output)
                    i=$((i + 1))
                    OUTPUT_FILE="${COMMAND_ARGS[$i]}"
                    ;;
                *)
                    # Image name
                    IMAGE_NAME="$arg"
                    ;;
            esac
            i=$((i + 1))
        done

        if [ -z "$OUTPUT_FILE" ]; then
            echo -e "${RED}[vdkr]${NC} save requires -o <file>" >&2
            exit 1
        fi

        if [ -z "$IMAGE_NAME" ]; then
            echo -e "${RED}[vdkr]${NC} save requires <image> name" >&2
            exit 1
        fi

        # Use --output-type tar to get docker save output
        RUNNER_ARGS=$(build_runner_args)
        # Override output type for save command
        RUNNER_ARGS=$(echo "$RUNNER_ARGS" | sed 's/--output-type storage//')
        "$RUNNER" $RUNNER_ARGS --output-type tar --output "$OUTPUT_FILE" \
            -- "docker save -o /tmp/output.tar $IMAGE_NAME"
        ;;

    tag|rmi)
        # Commands that work with existing images
        RUNNER_ARGS=$(build_runner_args)
        "$RUNNER" $RUNNER_ARGS -- "docker $COMMAND ${COMMAND_ARGS[*]}"
        ;;

    clean)
        # Remove persistent state for current architecture
        CLEAN_DIR="$DEFAULT_STATE_DIR/$TARGET_ARCH"
        if [ -d "$CLEAN_DIR" ]; then
            echo -e "${YELLOW}[vdkr]${NC} Removing state directory: $CLEAN_DIR"
            rm -rf "$CLEAN_DIR"
            echo -e "${GREEN}[vdkr]${NC} State cleaned. Next run will start fresh."
        else
            echo -e "${GREEN}[vdkr]${NC} No state directory found for $TARGET_ARCH"
        fi

        # Also show other architectures if present
        if [ -d "$DEFAULT_STATE_DIR" ]; then
            OTHER_ARCHS=$(ls "$DEFAULT_STATE_DIR" 2>/dev/null | grep -v "^$TARGET_ARCH$" || true)
            if [ -n "$OTHER_ARCHS" ]; then
                echo ""
                echo "Other architecture states present:"
                for arch in $OTHER_ARCHS; do
                    SIZE=$(du -sh "$DEFAULT_STATE_DIR/$arch" 2>/dev/null | cut -f1)
                    echo "  - $arch ($SIZE) - use 'vdkr-$arch clean' or 'rm -rf $DEFAULT_STATE_DIR/$arch'"
                done
            fi
        fi
        ;;

    info)
        RUNNER_ARGS=$(build_runner_args)
        "$RUNNER" $RUNNER_ARGS -- docker info
        ;;

    version)
        RUNNER_ARGS=$(build_runner_args)
        "$RUNNER" $RUNNER_ARGS -- docker version
        ;;

    vrun)
        # Extended run: run a command in a container (non-interactive)
        # Usage: vdkr vrun <image> [command] [args...]
        if [ ${#COMMAND_ARGS[@]} -lt 1 ]; then
            echo -e "${RED}[vdkr]${NC} vrun requires <image> [command] [args...]" >&2
            echo "Usage: vdkr vrun myimage:latest /bin/ls -la" >&2
            echo "       vdkr vrun myimage:latest  # runs default entrypoint" >&2
            exit 1
        fi

        IMAGE_NAME="${COMMAND_ARGS[0]}"
        CONTAINER_CMD=""

        # Build command from remaining args
        for ((i=1; i<${#COMMAND_ARGS[@]}; i++)); do
            if [ -n "$CONTAINER_CMD" ]; then
                CONTAINER_CMD="$CONTAINER_CMD ${COMMAND_ARGS[$i]}"
            else
                CONTAINER_CMD="${COMMAND_ARGS[$i]}"
            fi
        done

        # Build docker run command
        if [ -n "$CONTAINER_CMD" ]; then
            DOCKER_CMD="docker run --rm $IMAGE_NAME $CONTAINER_CMD"
        else
            DOCKER_CMD="docker run --rm $IMAGE_NAME"
        fi

        RUNNER_ARGS=$(build_runner_args)
        "$RUNNER" $RUNNER_ARGS -- "$DOCKER_CMD"
        ;;

    run)
        # Arbitrary docker command
        # Everything after 'run' is passed through
        if [ ${#COMMAND_ARGS[@]} -eq 0 ]; then
            echo -e "${RED}[vdkr]${NC} run requires a command" >&2
            echo "Usage: vdkr run -- <docker-command>" >&2
            exit 1
        fi

        # Check for -- separator
        DOCKER_CMD=""
        found_sep=false
        for arg in "${COMMAND_ARGS[@]}"; do
            if [ "$arg" = "--" ]; then
                found_sep=true
                continue
            fi
            if [ "$found_sep" = true ] || [ -n "$DOCKER_CMD" ]; then
                DOCKER_CMD="$DOCKER_CMD $arg"
            else
                DOCKER_CMD="$arg"
            fi
        done
        DOCKER_CMD="${DOCKER_CMD# }"  # trim leading space

        RUNNER_ARGS=$(build_runner_args)
        "$RUNNER" $RUNNER_ARGS -- "$DOCKER_CMD"
        ;;

    *)
        echo -e "${RED}[vdkr]${NC} Unknown command: $COMMAND" >&2
        echo "Run 'vdkr --help' for usage" >&2
        exit 1
        ;;
esac

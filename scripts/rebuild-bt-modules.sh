#!/bin/bash
#
# MediaTek MT7902 Bluetooth Module Rebuild Script
# Part of: https://github.com/ismailtrm/mt7902-bluetooth-arch-fix
#
# This script rebuilds MT7902 Bluetooth kernel modules for the currently
# running kernel by default, then restores firmware files from backup.
# Pacman hooks can opt into rebuilding all installed kernels with headers.
#

set -e

#############################################################################
# Configuration - Can be overridden via environment variables
#############################################################################

# Kernel version to build for; defaults to the currently running kernel.
TARGET_KERNEL_VERSION="${MT7902_KERNEL_VERSION:-$(uname -r)}"

# Build all installed kernels with headers when explicitly requested.
BUILD_ALL_KERNELS="${MT7902_BUILD_ALL_KERNELS:-0}"

# Root directory containing mt7902_temp kernel-version source trees.
# Default: ~/mt7902_temp
SOURCE_ROOT="${MT7902_SOURCE_ROOT:-$HOME/mt7902_temp}"

# Source directory containing MT7902 Bluetooth driver code.
# Default: $SOURCE_ROOT/linux-<target-kernel-major.minor>/drivers/bluetooth
SOURCE_DIR_OVERRIDE="${MT7902_SOURCE_DIR:-}"

# Backup directory containing firmware files
# Default: /opt/bluetooth-firmware-backup
BACKUP_DIR="${MT7902_BACKUP_DIR:-/opt/bluetooth-firmware-backup}"

# Log file location
LOG_FILE="${MT7902_LOG_FILE:-/var/log/bt-module-rebuild.log}"

# Firmware files to restore
FIRMWARE_DIR="/lib/firmware/mediatek"
FIRMWARE_FILES=(
    "BT_RAM_CODE_MT7902_1_1_hdr.bin"
    "mtkbt0.dat"
)

# Module files to build
MODULE_FILES=(
    "btmtk.ko"
    "btusb.ko"
)

#############################################################################
# Functions
#############################################################################

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

source_dir_for_kernel() {
    local KVER="$1"

    if [ -n "$SOURCE_DIR_OVERRIDE" ]; then
        printf '%s\n' "$SOURCE_DIR_OVERRIDE"
        return 0
    fi

    if [[ "$KVER" =~ ^([0-9]+)\.([0-9]+) ]]; then
        printf '%s/linux-%s.%s/drivers/bluetooth\n' \
            "$SOURCE_ROOT" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi

    return 1
}

validate_environment() {
    # Check if source directory exists
    if [ -n "$SOURCE_DIR_OVERRIDE" ]; then
        if [ ! -d "$SOURCE_DIR_OVERRIDE" ]; then
            error_exit "Source directory not found: $SOURCE_DIR_OVERRIDE

Please ensure mt7902_temp repository is cloned:
  git clone https://github.com/OnlineLearningTutorials/mt7902_temp ~/mt7902_temp

Or set MT7902_SOURCE_ROOT to the mt7902_temp path, or MT7902_SOURCE_DIR to the exact drivers/bluetooth path."
        fi
    elif [ ! -d "$SOURCE_ROOT" ]; then
        error_exit "Source root not found: $SOURCE_ROOT

Please ensure mt7902_temp repository is cloned:
  git clone https://github.com/OnlineLearningTutorials/mt7902_temp ~/mt7902_temp

Or set MT7902_SOURCE_ROOT to the mt7902_temp path."
    fi

    # Check if backup directory exists
    if [ ! -d "$BACKUP_DIR" ]; then
        error_exit "Backup directory not found: $BACKUP_DIR

Please run the installer or create backup directory with firmware files."
    fi

    # Check if firmware files exist in backup
    for fw_file in "${FIRMWARE_FILES[@]}"; do
        if [ ! -f "$BACKUP_DIR/$fw_file" ]; then
            error_exit "Firmware file not found in backup: $BACKUP_DIR/$fw_file

Please extract firmware from Windows and copy to backup directory."
        fi
    done

    if [ "$BUILD_ALL_KERNELS" = "1" ]; then
        local has_kernel=false
        for kdir in /lib/modules/*/build; do
            if [ -d "$kdir" ]; then
                has_kernel=true
                break
            fi
        done

        if [ ! "$has_kernel" = true ]; then
            error_exit "No kernel headers found. Please install the matching headers package for your kernel."
        fi
    elif [ ! -d "/lib/modules/$TARGET_KERNEL_VERSION/build" ]; then
        error_exit "No kernel headers found for target kernel: $TARGET_KERNEL_VERSION

Please install the matching headers package for your current kernel.
Examples:
  sudo pacman -S linux-headers
  sudo pacman -S linux-lts-headers
  sudo pacman -S linux-zen-headers

If you just upgraded the kernel, reboot into the new kernel first."
    fi
}

build_modules_for_kernel() {
    local KVER="$1"
    local KDIR="/lib/modules/$KVER/build"
    local UPDATES_DIR="/lib/modules/$KVER/updates"
    local BUILD_SOURCE_DIR

    if ! BUILD_SOURCE_DIR="$(source_dir_for_kernel "$KVER")"; then
        log "ERROR: Could not determine driver source for kernel $KVER"
        return 1
    fi

    if [ ! -d "$BUILD_SOURCE_DIR" ]; then
        log "ERROR: Driver source not found for kernel $KVER: $BUILD_SOURCE_DIR"
        return 1
    fi

    log "Building modules for kernel $KVER"
    log "  Source: $BUILD_SOURCE_DIR"

    # Create updates directory if needed
    mkdir -p "$UPDATES_DIR"

    # Clean previous build artifacts
    cd "$BUILD_SOURCE_DIR"
    make -C "$KDIR" M="$BUILD_SOURCE_DIR" clean 2>/dev/null || true

    # Build modules for this kernel version
    if make -C "$KDIR" M="$BUILD_SOURCE_DIR" modules >> "$LOG_FILE" 2>&1; then
        log "Build successful for $KVER"
        local missing_module=false

        # Copy modules to updates directory
        for module in "${MODULE_FILES[@]}"; do
            if [ -f "$BUILD_SOURCE_DIR/$module" ]; then
                cp "$BUILD_SOURCE_DIR/$module" "$UPDATES_DIR/"
                log "  Installed: $module"
            else
                log "  ERROR: Module not found after build: $module"
                missing_module=true
            fi
        done

        if [ "$missing_module" = true ]; then
            return 1
        fi

        # Update module dependencies
        depmod "$KVER"
        log "Modules installed and dependencies updated for $KVER"
        return 0
    else
        log "ERROR: Build failed for $KVER (check log for details)"
        return 1
    fi
}

restore_firmware() {
    log "Restoring firmware files"

    # Ensure firmware directory exists
    mkdir -p "$FIRMWARE_DIR"

    # Copy firmware files from backup
    for fw_file in "${FIRMWARE_FILES[@]}"; do
        if [ -f "$BACKUP_DIR/$fw_file" ]; then
            cp -f "$BACKUP_DIR/$fw_file" "$FIRMWARE_DIR/"
            log "  Restored: $fw_file"
        else
            log "  WARNING: Firmware file not found in backup: $fw_file"
        fi
    done
}

process_kernel() {
    local KVER="$1"
    local UPDATES_DIR="/lib/modules/$KVER/updates"
    local all_modules_exist=true

    for module in "${MODULE_FILES[@]}"; do
        if [ ! -f "$UPDATES_DIR/$module" ]; then
            all_modules_exist=false
            break
        fi
    done

    if [ "$all_modules_exist" = true ]; then
        log "Modules already exist for $KVER, skipping"
        # Plain assignment, not ((skip_count++)): a post-increment from 0
        # returns exit status 1, which `set -e` treats as a fatal error.
        skip_count=$((skip_count + 1))
        return 0
    fi

    if build_modules_for_kernel "$KVER"; then
        # Plain assignment, not ((build_count++)): a post-increment from 0
        # returns exit status 1, which `set -e` treats as a fatal error.
        build_count=$((build_count + 1))
    else
        build_failed=true
    fi
}

#############################################################################
# Main Script
#############################################################################

log "=== Starting MT7902 Bluetooth module rebuild ==="

# Validate environment and prerequisites
validate_environment

# Build only for the currently running kernel by default.
build_count=0
skip_count=0
build_failed=false

if [ "$BUILD_ALL_KERNELS" = "1" ]; then
    for KDIR in /lib/modules/*/build; do
        [ -d "$KDIR" ] || continue
        KVER=$(basename "$(dirname "$KDIR")")
        process_kernel "$KVER"
    done
else
    process_kernel "$TARGET_KERNEL_VERSION"
fi

# Restore firmware files
restore_firmware

# Summary
if [ "$build_failed" = true ]; then
    log "=== Bluetooth module rebuild failed ==="
    log "Summary: Built for $build_count kernel(s), skipped $skip_count kernel(s)"
    exit 1
fi

log "=== Bluetooth module rebuild complete ==="
log "Summary: Built for $build_count kernel(s), skipped $skip_count kernel(s)"

exit 0

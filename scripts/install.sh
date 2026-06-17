#!/bin/bash
#
# MediaTek MT7902 Bluetooth Fix - Automated Installer
# Part of: https://github.com/ismailtrm/mt7902-bluetooth-arch-fix
#
# This installer automates the setup process for MT7902 Bluetooth fix on Arch Linux.
# It handles prerequisite checks, source cloning, firmware extraction, and hook installation.
#

set -e

#############################################################################
# Configuration
#############################################################################

REPO_URL="https://github.com/OnlineLearningTutorials/mt7902_temp"
DEFAULT_SOURCE_DIR="$HOME/mt7902_temp"
BACKUP_DIR="/opt/bluetooth-firmware-backup"
HOOK_DIR="/etc/pacman.d/hooks"
FIRMWARE_DIR="/lib/firmware/mediatek"

# Firmware checksums for validation
declare -A FIRMWARE_CHECKSUMS=(
    ["BT_RAM_CODE_MT7902_1_1_hdr.bin"]="900a342bf03d5b844947aebe854af55d"
    ["mtkbt0.dat"]="bf4087994e011245aec5c76e7d938e07"
)

#############################################################################
# Colors and Formatting
#############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

error_exit() {
    error "$1"
    exit 1
}

#############################################################################
# Validation Functions
#############################################################################

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root or with sudo."
    fi
}

check_arch_linux() {
    if [ ! -f /etc/arch-release ]; then
        warn "This script is designed for Arch Linux and derivatives."
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        return 1
    fi
    return 0
}

detect_headers_package() {
    local kernel_version="$1"
    local pkgbase_file="/lib/modules/$kernel_version/pkgbase"
    local pkgbase=""

    if [ -r "$pkgbase_file" ]; then
        pkgbase="$(<"$pkgbase_file")"
        if [ -n "$pkgbase" ]; then
            printf '%s-headers\n' "$pkgbase"
            return 0
        fi
    fi

    case "$kernel_version" in
        *-arch*) printf 'linux-headers\n' ;;
        *-lts*) printf 'linux-lts-headers\n' ;;
        *-zen*) printf 'linux-zen-headers\n' ;;
        *-hardened*) printf 'linux-hardened-headers\n' ;;
        *) return 1 ;;
    esac
}

kernel_series() {
    local kernel_version="$1"

    if [[ "$kernel_version" =~ ^([0-9]+)\.([0-9]+) ]]; then
        printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return 0
    fi

    return 1
}

verify_checksum() {
    local file="$1"
    local expected_checksum="$2"

    if [ ! -f "$file" ]; then
        return 1
    fi

    local actual_checksum=$(md5sum "$file" | awk '{print $1}')

    if [ "$actual_checksum" = "$expected_checksum" ]; then
        return 0
    else
        warn "Checksum mismatch for $(basename "$file")"
        warn "  Expected: $expected_checksum"
        warn "  Got:      $actual_checksum"
        return 1
    fi
}

#############################################################################
# Installation Steps
#############################################################################

step_check_prerequisites() {
    info "Checking prerequisites..."

    local missing_packages=()
    local current_kernel
    local current_build_dir
    local current_headers_package

    current_kernel="$(uname -r)"
    current_build_dir="/lib/modules/$current_kernel/build"

    # Check required packages
    if [ ! -d "$current_build_dir" ]; then
        warn "Headers for the current kernel are missing: $current_build_dir"
        if current_headers_package="$(detect_headers_package "$current_kernel")"; then
            missing_packages+=("$current_headers_package")
        else
            error_exit "Could not determine the headers package for current kernel: $current_kernel

Install the matching headers package for your running kernel, then rerun this script.
If you just upgraded the kernel, reboot into the new kernel first."
        fi
    fi

    if ! pacman -Q base-devel &>/dev/null; then
        missing_packages+=("base-devel")
    fi

    if ! check_command git; then
        missing_packages+=("git")
    fi

    if [ ${#missing_packages[@]} -gt 0 ]; then
        warn "Missing required packages: ${missing_packages[*]}"
        read -p "Install now? (Y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            pacman -S --needed "${missing_packages[@]}"
        else
            error_exit "Required packages not installed."
        fi
    fi

    if [ ! -d "$current_build_dir" ]; then
        error_exit "Headers for the current kernel are still missing: $current_build_dir

Install the matching headers package for $current_kernel, then rerun this script.
If you just upgraded the kernel, reboot into the new kernel first."
    fi

    success "All prerequisites met for current kernel: $current_kernel"
}

step_clone_source() {
    info "Setting up MT7902 driver source..."

    # Get actual user's home directory (even when running with sudo)
    local REAL_USER="${SUDO_USER:-$USER}"
    local REAL_HOME=$(eval echo "~$REAL_USER")
    local current_kernel
    local current_series
    local driver_source_dir
    DEFAULT_SOURCE_DIR="${MT7902_SOURCE_ROOT:-$REAL_HOME/mt7902_temp}"

    if [ -d "$DEFAULT_SOURCE_DIR" ]; then
        success "Source directory already exists: $DEFAULT_SOURCE_DIR"
        read -p "Use existing directory? (Y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            read -p "Enter alternative mt7902_temp root path: " SOURCE_DIR
        else
            SOURCE_DIR="$DEFAULT_SOURCE_DIR"
        fi
    else
        info "Cloning mt7902_temp repository..."
        sudo -u "$REAL_USER" git clone "$REPO_URL" "$DEFAULT_SOURCE_DIR"
        SOURCE_DIR="$DEFAULT_SOURCE_DIR"
        success "Source cloned to: $SOURCE_DIR"
    fi

    current_kernel="$(uname -r)"
    if ! current_series="$(kernel_series "$current_kernel")"; then
        error_exit "Could not determine kernel source series from current kernel: $current_kernel"
    fi

    driver_source_dir="$SOURCE_DIR/linux-$current_series/drivers/bluetooth"
    if [ ! -d "$driver_source_dir" ]; then
        error_exit "Driver source for current kernel $current_kernel was not found: $driver_source_dir

Ensure mt7902_temp contains linux-$current_series support."
    fi

    # Export for rebuild script and pacman hook installation.
    export MT7902_SOURCE_ROOT="$SOURCE_DIR"
    export MT7902_SOURCE_DIR="$driver_source_dir"
    success "Using driver source for current kernel ($current_kernel): $MT7902_SOURCE_DIR"
}

step_get_firmware() {
    info "Setting up firmware files..."

    echo ""
    echo "You need two firmware files:"
    echo "  1. BT_RAM_CODE_MT7902_1_1_hdr.bin"
    echo "  2. mtkbt0.dat"
    echo ""
    echo "Options:"
    echo "  [1] Extract from Windows dual-boot (recommended)"
    echo "  [2] Provide path to existing firmware files"
    echo ""

    read -p "Choose option (1 or 2): " -n 1 -r
    echo

    case $REPLY in
        1)
            extract_from_windows
            ;;
        2)
            provide_firmware_path
            ;;
        *)
            error_exit "Invalid option"
            ;;
    esac
}

extract_from_windows() {
    info "Detecting Windows partition..."

    # List NTFS partitions
    local partitions=$(lsblk -f | grep ntfs | awk '{print $1}')

    if [ -z "$partitions" ]; then
        error_exit "No NTFS partitions found. Please use option 2 to provide firmware files manually."
    fi

    echo ""
    echo "NTFS partitions found:"
    lsblk -f | grep ntfs
    echo ""

    read -p "Enter Windows partition (e.g., nvme0n1p3): " partition

    local mount_point="/mnt/windows_temp"
    mkdir -p "$mount_point"

    info "Mounting /dev/$partition..."
    if ! mount -t ntfs3 -o ro "/dev/$partition" "$mount_point"; then
        error_exit "Failed to mount Windows partition"
    fi

    # Extract firmware
    local win_driver_path="$mount_point/Windows/System32/drivers"

    mkdir -p "$BACKUP_DIR"

    for fw_file in "${!FIRMWARE_CHECKSUMS[@]}"; do
        local src="$win_driver_path/$fw_file"
        local dst="$BACKUP_DIR/$fw_file"

        if [ -f "$src" ]; then
            cp "$src" "$dst"
            if verify_checksum "$dst" "${FIRMWARE_CHECKSUMS[$fw_file]}"; then
                success "Extracted and verified: $fw_file"
            else
                error "Checksum verification failed for $fw_file"
            fi
        else
            error "Firmware file not found: $src"
        fi
    done

    umount "$mount_point"
    rmdir "$mount_point"
}

provide_firmware_path() {
    info "Please provide the path to your firmware files..."

    read -p "Enter directory containing firmware files: " fw_dir

    if [ ! -d "$fw_dir" ]; then
        error_exit "Directory not found: $fw_dir"
    fi

    mkdir -p "$BACKUP_DIR"

    for fw_file in "${!FIRMWARE_CHECKSUMS[@]}"; do
        local src="$fw_dir/$fw_file"
        local dst="$BACKUP_DIR/$fw_file"

        if [ -f "$src" ]; then
            cp "$src" "$dst"
            if verify_checksum "$dst" "${FIRMWARE_CHECKSUMS[$fw_file]}"; then
                success "Copied and verified: $fw_file"
            else
                error "Checksum verification failed for $fw_file"
            fi
        else
            error "Firmware file not found: $src"
        fi
    done
}

step_install_scripts() {
    info "Installing rebuild script..."

    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    cp "$script_dir/rebuild-bt-modules.sh" "$BACKUP_DIR/"
    chmod +x "$BACKUP_DIR/rebuild-bt-modules.sh"

    success "Rebuild script installed to: $BACKUP_DIR/rebuild-bt-modules.sh"
}

step_install_hook() {
    info "Installing pacman hook..."

    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local hook_src="$script_dir/../hooks/bluetooth-firmware.hook"

    # step_clone_source must have resolved and exported this already.
    if [ -z "$MT7902_SOURCE_ROOT" ]; then
        error_exit "MT7902_SOURCE_ROOT is not set; step_clone_source must run first."
    fi

    mkdir -p "$HOOK_DIR"
    # Bake the absolute driver source root into the hook's Exec line.
    # pacman runs hooks as root, so the rebuild script's $HOME-relative
    # default would resolve to /root and fail -- the path must be explicit.
    sed "s|@@MT7902_SOURCE_ROOT@@|${MT7902_SOURCE_ROOT}|g" "$hook_src" \
        > "$HOOK_DIR/bluetooth-firmware.hook"

    success "Pacman hook installed to: $HOOK_DIR/bluetooth-firmware.hook"
    info "  Driver source root baked into hook: $MT7902_SOURCE_ROOT"
}

step_test_rebuild() {
    info "Testing rebuild script..."

    if "$BACKUP_DIR/rebuild-bt-modules.sh"; then
        success "Rebuild script executed successfully"

        echo ""
        info "Checking log output..."
        tail -10 /var/log/bt-module-rebuild.log
        echo ""

        return 0
    else
        error "Rebuild script failed"
        return 1
    fi
}

#############################################################################
# Main Installation
#############################################################################

main() {
    echo ""
    echo "=========================================="
    echo " MT7902 Bluetooth Fix Installer"
    echo " for Arch Linux"
    echo "=========================================="
    echo ""

    check_root
    check_arch_linux

    step_check_prerequisites
    step_clone_source
    step_get_firmware
    step_install_scripts
    step_install_hook

    if step_test_rebuild; then
        echo ""
        echo "=========================================="
        success "Installation complete!"
        echo "=========================================="
        echo ""
        echo "Next steps:"
        echo "  1. Reboot your system"
        echo "  2. After reboot, verify Bluetooth:"
        echo "     bluetoothctl show"
        echo ""
        echo "The pacman hook will automatically rebuild"
        echo "modules after future kernel updates."
        echo ""
        echo "Logs: /var/log/bt-module-rebuild.log"
        echo "=========================================="
    else
        echo ""
        error "Installation completed with errors."
        echo "Please check /var/log/bt-module-rebuild.log"
        exit 1
    fi
}

main "$@"

#!/usr/bin/env bash
# setup.sh — Install Intel IPU6 camera support on AlmaLinux 10.1 / RHEL 10 / kernel 6.12
# Usage: sudo bash setup.sh [OPTIONS]
#
# This script uses the submodules bundled in this repo:
#   ipu6-drivers/      — intel/ipu6-drivers @ da921f7 (2026-03-15)
#   ipu6-camera-bins/  — intel/ipu6-camera-bins @ 30e8766 (2026-03-15)
#
# Options:
#   --dry-run  Print all steps without executing anything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

info()  { echo "==> $*"; }
warn()  { echo "WARN: $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
    die "This script must be run as root (sudo bash setup.sh)"
fi

# ── Kernel version check ──────────────────────────────────────────────────────
KVER="$(uname -r)"
info "Running on kernel $KVER"
if [[ "$KVER" != 6.12.* ]]; then
    warn "This script was tested on kernel 6.12.x; you are running $KVER"
    warn "Proceeding anyway — review patches manually if the build fails."
fi

# ── Step 1: Install build dependencies ───────────────────────────────────────
info "Step 1: Install build dependencies"
run dnf install -y epel-release
run dnf install -y dkms gcc make kernel-devel-"${KVER}"

# ── Reboot guard: dkms dependency may pull in a newer kernel ──────────────────
# dnf install dkms hard-depends on kernel-devel-matched which pulls in
# kernel-core + kernel-modules-core for the latest kernel. Only core modules
# are installed — kernel-modules (wifi, GPU, etc.) is not. We install the full
# module set here, then require a reboot so Steps 2-7 run on the correct kernel.
if [[ $DRY_RUN -eq 0 ]]; then
    LATEST_KVER=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null \
        | sort -V | tail -1)
    if [[ -n "$LATEST_KVER" && "$LATEST_KVER" != "$KVER" ]]; then
        info "New kernel detected: $LATEST_KVER (running: $KVER)"
        info "Installing full kernel module set for $LATEST_KVER before reboot..."
        run dnf install -y \
            "kernel-modules-${LATEST_KVER}" \
            "kernel-modules-extra-${LATEST_KVER}"
        echo ""
        echo "========================================================"
        echo " Reboot required before the DKMS build can proceed."
        echo " The new kernel's full driver set is now installed."
        echo ""
        echo " After rebooting, re-run this script:"
        echo "   sudo bash $0"
        echo "========================================================"
        exit 0
    fi
fi

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in git dkms dracut curl; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done

# ── Submodule check ───────────────────────────────────────────────────────────
DRIVERS_DIR="$SCRIPT_DIR/ipu6-drivers"
BINS_DIR="$SCRIPT_DIR/ipu6-camera-bins"

if [[ ! -f "$DRIVERS_DIR/dkms.conf" || ! -f "$BINS_DIR/lib/firmware/intel/ipu/ipu6epmtl_fw.bin" ]]; then
    die "Submodules are not initialized. Run:
    git submodule update --init --recursive"
fi

# Derive DKMS version directly from dkms.conf to stay in sync; strip any quotes
DKMS_VER="$(grep '^PACKAGE_VERSION=' "$DRIVERS_DIR/dkms.conf" | cut -d= -f2 | tr -d '"'"'")"
[[ -n "$DKMS_VER" ]] || die "Could not parse PACKAGE_VERSION from dkms.conf"
DKMS_SRC="/usr/src/ipu6-drivers-${DKMS_VER}"

# ── Step 2: Copy submodule to DKMS source tree ───────────────────────────────
info "Step 2: Copy ipu6-drivers to DKMS source tree (version $DKMS_VER)"
# Remove any previous build to avoid stale files from prior runs.
run rm -rf "$DKMS_SRC"
run mkdir -p "$DKMS_SRC"
# Exclude .git: the submodule's .git file is a pointer that becomes invalid
# once relocated to /usr/src; remove it so patch(1) (which needs no repo) is used.
run cp -r "$DRIVERS_DIR/." "$DKMS_SRC/"
run rm -f "$DKMS_SRC/.git"

# ── Step 3: Apply patches ─────────────────────────────────────────────────────
info "Step 3: Apply AlmaLinux compatibility patches"
PATCHES_DIR="$SCRIPT_DIR/patches"

for patch in \
    "0001-dkms-conf-fix-module-array-gaps.patch" \
    "0002-makefile-guard-ov05c10-v4l2-cci.patch" \
    "0003-psys-module-import-ns-rhel-compat.patch"
do
    pfile="$PATCHES_DIR/$patch"
    [[ -f "$pfile" ]] || die "Patch not found: $pfile"
    info "  Applying $patch"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] patch -p1 -d $DKMS_SRC < $pfile"
    else
        patch -p1 -d "$DKMS_SRC" < "$pfile"
    fi
done

# ── Step 4: Install via DKMS ──────────────────────────────────────────────────
info "Step 4: Install ipu6-drivers via DKMS"
run dkms add "ipu6-drivers/${DKMS_VER}"
run dkms build "ipu6-drivers/${DKMS_VER}"
run dkms install "ipu6-drivers/${DKMS_VER}"

# ── Step 5: Install IPU6 EP MTL firmware ──────────────────────────────────────
info "Step 5: Install IPU6 EP MTL firmware"
FW_SRC="$BINS_DIR/lib/firmware/intel/ipu/ipu6epmtl_fw.bin"
FW_DEST="/lib/firmware/intel/ipu/ipu6epmtl_fw.bin"
run mkdir -p /lib/firmware/intel/ipu
run cp "$FW_SRC" "$FW_DEST"
info "  Installed: $FW_DEST"

# ── Step 6: Install VSC firmware ─────────────────────────────────────────────
info "Step 6: Install VSC firmware"
run mkdir -p /lib/firmware/intel/vsc

VSC_BASE="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/intel/vsc"

for fw in \
    "ivsc_fw.bin" \
    "ivsc_pkg_ovti02c1_0.bin" \
    "ivsc_skucfg_ovti02c1_0_1.bin"
do
    if [[ $DRY_RUN -eq 0 && -f "/lib/firmware/intel/vsc/${fw}" ]]; then
        info "  Skipping $fw (already present)"
        continue
    fi
    info "  Downloading $fw..."
    run curl -fsSL "${VSC_BASE}/${fw}" -o "/lib/firmware/intel/vsc/${fw}"
done

# ── Step 7: Rebuild initramfs ──────────────────────────────────────────────────
info "Step 7: Rebuild initramfs"
run dracut --force
info "  initramfs rebuilt."

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "========================================================"
echo " Setup complete!  Verify after reboot with:"
echo ""
echo "   sudo dmesg | grep -E '(intel_vsc|ivsc|ipu6|ipu_bridge|OVTI|ov02c10)' \\"
echo "     | grep -v 'bridge window'"
echo ""
echo "   ls /dev/video* /dev/media*"
echo ""
echo " A working system shows /dev/media0 and ~48 /dev/video* nodes."
echo "========================================================"
echo ""

echo "Remember to reboot before testing the camera."

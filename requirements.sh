#!/bin/bash
# =============================================================================
# requirements.sh - Install build dependencies for NetHunter kernel building
# =============================================================================
# Run: chmod +x requirements.sh && ./requirements.sh
# OS: Kali Linux, Ubuntu 20.04+, or Debian
# =============================================================================

set -e

echo "Installing build dependencies for NetHunter kernel building..."
echo "OS detected as: $(cat /etc/os-release | grep "^ID=" | cut -d= -f2)"

# Update package list
sudo apt update -y

# Core build tools.
# NOTE: only packages that exist in Debian/Kali are listed - a single unknown
# package name makes apt abort the whole transaction, leaving you with nothing
# installed.  There is no "android-sdk" or "mkbootimg" package and no GCC
# toolchain is needed (the kernel is built with AOSP clang + lld + LLVM IAS).
sudo apt install -y \
    build-essential \
    bc \
    binutils \
    bison \
    flex \
    libncurses-dev \
    libssl-dev \
    libelf-dev \
    device-tree-compiler \
    python3 \
    python3-dev \
    xz-utils \
    lz4 \
    zstd \
    zip \
    unzip \
    git \
    git-lfs \
    wget \
    curl \
    ccache \
    rsync \
    cpio \
    kmod \
    libxml2-utils \
    xsltproc \
    adb \
    fastboot

# Additional packages that may be useful
sudo apt install -y \
    axel \
    pandoc \
    lynx \
    whiptail \
    fakeroot \
    2>/dev/null || true

echo ""
echo "========================================"
echo " Dependencies installed successfully!"
echo "========================================"
echo ""
echo "Next steps:"
echo ""
echo "1. Keep this checkout on an ext4 filesystem (NTFS/exFAT breaks netfilter builds)."
echo ""
echo "2. Find out what release string your ROM's kernel modules were built for:"
echo "     adb shell uname -r"
echo ""
echo "3. Build (the toolchain is downloaded automatically):"
echo "     STOCK_RELEASE=\"\$(adb shell uname -r)\" ./build-nethunter-kernel.sh"
echo ""
echo "No GCC toolchain is required: the device tree sets"
echo "TARGET_KERNEL_NO_GCC := true, so the kernel is built with AOSP clang,"
echo "ld.lld and the LLVM integrated assembler."
echo ""
echo "Done! You can now build the NetHunter kernel."

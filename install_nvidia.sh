#!/bin/bash
# =============================================================================
# NVIDIA Accelerated Graphics Driver for Linux-x86_64 + NVIDIA Container Toolkit Installer for Debian (trixie)
#
# This script automates the installation, configuration, and management of
# the proprietary NVIDIA GPU driver and NVIDIA Container Toolkit on Debian 13.
#
# Features:
# - Installs the latest NVIDIA production driver (DKMS-enabled) 
# - Prompts to install and configures NVIDIA Container Toolkit for Docker GPU support
# - Rebuilds DKMS modules for new kernels
# - Supports uninstall and cleanup of all related components
#
# Usage:
#   sudo bash install_nvidia.sh [--install|--rebuild|--status|--version|--uninstall [VER]]

set -e

trap abort SIGINT SIGTERM ERR

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use: sudo bash $0"
    exit 1
fi

# Function to display usage
display_usage() {
    echo "Usage: sudo bash $0 [OPTION]"
    echo "Options:"
    echo "  --install           Automatically run pre-reboot or post-reboot installation steps as needed"
    echo "  --rebuild           Rebuild the NVIDIA DKMS module for the current kernel"
    echo "  --status            Show driver, GPU, and container runtime status"
    echo "  --version           Show installed and latest available stable NVIDIA driver versions"
    echo "  --uninstall [VER]   Uninstall the NVIDIA driver and toolkit (optionally specify version)"
}

# Function to prompt for reboot
prompt_reboot() {
    read -p "Reboot is required to apply changes. Do you want to reboot now? (y/N): " choice
    case "$choice" in
        y|Y ) reboot ;;
        * ) echo "Please reboot manually later to apply changes." ;;
    esac
}

# Function to prompt for restart docker
prompt_restart_docker() {
    read -p "Do you want to restart Docker now to apply changes? [y/N]: " choice
    case "$choice" in
        [Yy]*) systemctl restart docker ;;
        *) echo "Docker not restarted. You may need to restart it manually later." ;;
    esac
}

abort() {
    echo "Script interrupted or failed."
    unmask_docker || true
    exit 1
}

stop_docker_if_running() {
    if command -v docker >/dev/null 2>&1; then
        containers="$(docker ps -q 2>/dev/null || true)"
        if [ -n "${containers:-}" ]; then
            echo "Stopping Docker containers..."
            docker stop $containers >/dev/null 2>&1 || true
        fi
    fi

    if systemctl is-active --quiet docker 2>/dev/null; then
        echo "Stopping Docker service..."
        systemctl stop docker >/dev/null 2>&1 || true
    fi

    echo "Masking Docker service..."
    systemctl mask docker >/dev/null 2>&1 || true
}

unmask_docker() {
    echo "Unmasking Docker service..."
    systemctl unmask docker >/dev/null 2>&1 || true
}

ensure_base_tools() {
    apt update -y
    apt install -y --no-install-recommends ca-certificates curl gpg jq dkms
}

# Function to fetch latest production branch version
fetch_latest_version() {

    local PROD_BRANCH='Latest Production Branch Version'
    local NEW_FEATURE_BRANCH='Latest New Feature Branch Version'
    local BETA_BRANCH='Latest Beta Version'
    
    local regex="${PROD_BRANCH}:</span>\\s*<a href=\\\"[^\\\"]*\\\">\\s*\\K[0-9]+\\.[0-9]+(\\.[0-9]+)?"

    # Fetch the page and extract the first matching version number.
    curl -s https://www.nvidia.com/en-us/drivers/unix/ \
        | grep -oP "$regex" \
        | head -n 1
}

# Function to get installed version
get_installed_version() {
    if command -v nvidia-smi >/dev/null; then
        nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1
    else
        DKMS_NVIDIA=$(dkms status | grep '^nvidia/' | head -1)
        if [ -n "$DKMS_NVIDIA" ]; then
            echo "$DKMS_NVIDIA" | cut -d'/' -f2 | cut -d',' -f1 | sed 's/ //g'
        else
            echo ""
        fi
    fi
}

status() {
    echo "Checking NVIDIA and Docker GPU status..."
    status_failed=false

    # DKMS status for NVIDIA
    dkms_nvidia=$(dkms status | grep '^nvidia/' || true)
    if [ -n "$dkms_nvidia" ]; then
        echo "DKMS NVIDIA module: $dkms_nvidia"
    else
        echo "No NVIDIA DKMS module found."
        status_failed=true
    fi

    echo 
    # NVIDIA driver versions and GPU info
    if command -v nvidia-smi >/dev/null; then
    gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
        echo "GPU: $gpu_name"
        version_output=$(nvidia-smi --version 2>&1)
        echo "$version_output"
    else
        echo "NVIDIA driver not detected."
        status_failed=true
    fi

    echo 
    # NVIDIA Container Toolkit
    ctk_version=$(nvidia-ctk --version 2>/dev/null | grep 'version' || true)
    if [ -n "$ctk_version" ]; then
        echo "$ctk_version"
    else
        echo "NVIDIA Container Toolkit not found."
        status_failed=true
    fi

    # Docker GPU test with versions and GPU info
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        docker_version_output=$(docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu24.04 nvidia-smi --version 2>&1 || echo "failed")
        if [ "$docker_version_output" = "failed" ]; then
            echo "Docker GPU test failed."
            status_failed=true
        else
            docker_gpu_name=$(docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu24.04 nvidia-smi --query-gpu=name --format=csv,noheader 2>&1 | head -1)
            echo "DOCKER: GPU: $docker_gpu_name"
            echo "$docker_version_output" | sed 's/^/DOCKER: /'
        fi
    else
        echo "Docker not available/running; skipping Docker GPU test."
    fi

    if [ "$status_failed" = true ]; then
        echo -e "Driver installation validation failed. \n"
        display_usage
    fi
}

show_version() {
    echo installed $(get_installed_version), latest stable $(fetch_latest_version)
}

uninstall() {
    ensure_base_tools

    if [ -n "$2" ]; then
        DRIVER_VERSION="$2"
    else
        DRIVER_VERSION=$(get_installed_version)
    fi
    if [ -z "$DRIVER_VERSION" ]; then
        echo "No installed NVIDIA driver detected. Cleaning up toolkit and configurations anyway."
        # Proceed without driver uninstall
    else
        DRIVER_FILE="NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
        DOWNLOAD_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION}/${DRIVER_FILE}"
    fi

    # Uninstall steps
    echo "Uninstalling NVIDIA Container Toolkit..."
    apt purge -y nvidia-container-toolkit || true
    rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
    #rm -f /etc/apt/sources.list.d/non-free-firmware.list
    apt update

    if [ -n "$DRIVER_VERSION" ]; then
        echo "Uninstalling NVIDIA driver version $DRIVER_VERSION..."
        if [ -f /usr/bin/nvidia-uninstall ]; then
            echo "Using existing nvidia-uninstall tool..."
            /usr/bin/nvidia-uninstall --silent || true
        else
            cd /tmp
            if [ ! -f "$DRIVER_FILE" ]; then
                echo "Driver installer not found in /tmp. Downloading it..."
                curl -fSLO "$DOWNLOAD_URL" || { echo "Failed to download installer."; exit 1; }
            fi
            chmod +x "$DRIVER_FILE"
            ./"$DRIVER_FILE" --uninstall --silent || true
            rm -f "$DRIVER_FILE"
        fi

        echo "Attempting DKMS removal as fallback..."
        dkms remove -m nvidia -v "$DRIVER_VERSION" --all || true

        # Purge any apt-installed NVIDIA packages
        apt purge -y '~nvidia' || true
    else
        echo "Skipping driver uninstall as no version detected."
    fi

    # Remove configurations
    rm -f /etc/modprobe.d/blacklist-nouveau.conf
    rm -f /etc/modprobe.d/nvidia.conf
    update-initramfs -u

    # Revert Docker configuration
    if [ -f /etc/docker/daemon.json ]; then
        if jq -e . >/dev/null 2>&1 </etc/docker/daemon.json; then
            tmp="$(mktemp)"
            jq '
            if has("runtimes") and (.runtimes | has("nvidia")) then
                .runtimes |= (del(.nvidia) | (if (keys | length)==0 then empty else . end))
            else . end
            | if has("default-runtime") and ."default-runtime"=="nvidia" then del(."default-runtime") else . end
            ' /etc/docker/daemon.json >"$tmp" && mv "$tmp" /etc/docker/daemon.json
        else
            echo "Warning: /etc/docker/daemon.json is not valid JSON; not modifying."
        fi
    fi

    # Clean up
    apt autoremove -y

    echo "Uninstallation complete."
    prompt_reboot
}

blacklist_nouveau() {
    cat << EOF > /etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF
    update-initramfs -u
    echo "Reboot required before continuing installation."
    prompt_reboot
}

# Function to check install prerequisites
check_install_prerequisites() {
    # If any APT source already includes non-free-firmware, we're done.
    if grep -E '^deb .*non-free-firmware' /etc/apt/sources.list /etc/apt/sources.list.d/* >/dev/null 2>&1; then
        return 0
    fi

    echo "Warning: 'non-free-firmware' not found in APT sources."
    
    # Identify the codename from /etc/os-release (e.g., trixie)
    codename=$(grep '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
    if [ -z "$codename" ]; then
        echo "Could not detect codename (e.g., trixie) from /etc/os-release."
        read -p "Please enter your Debian codename manually: " codename
    fi

    # Use 'stable' if detected in existing sources
    if grep -q '^deb .*debian stable main' /etc/apt/sources.list /etc/apt/sources.list.d/*; then
        codename="stable"
    fi

    new_source="deb http://deb.debian.org/debian $codename main contrib non-free-firmware"
    echo "$new_source" | tee /etc/apt/sources.list.d/non-free-firmware.list >/dev/null
    apt update
}

install_driver() {
    ensure_base_tools
    check_install_prerequisites

    # Check if kernel headers package exists
    if ! apt-cache show "linux-headers-$(uname -r)" >/dev/null 2>&1; then
        echo "Error: Kernel headers for $(uname -r) not found in repository."
        exit 1
    fi
    apt install -y  --no-install-recommends \
        linux-headers-$(uname -r) build-essential pkg-config libglvnd-dev firmware-misc-nonfree

    DRIVER_VERSION=$(fetch_latest_version)
    if [ -z "$DRIVER_VERSION" ]; then
        read -p "Failed to fetch latest version. Enter driver version (default: 570.181): " user_input
        DRIVER_VERSION="${user_input:-570.181}"
    fi

    installed="$(get_installed_version || true)"
    if [ "$installed" = "$DRIVER_VERSION" ]; then
        echo "Already on NVIDIA driver: $installed"
        return 0
    elif [ -n "$installed" ]; then
        echo "Different NVIDIA driver version detected: $installed"
        echo "Uninstalling existing version before proceeding..."
        
        stop_docker_if_running

        if [ -f /usr/bin/nvidia-uninstall ]; then
            echo "Using existing nvidia-uninstall tool..."
            /usr/bin/nvidia-uninstall --silent || true
        fi
    fi

    DRIVER_FILE="NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
    DOWNLOAD_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION}/${DRIVER_FILE}"

    # Post-reboot steps (installation forward)
    if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "display-manager.service"; then
        systemctl stop display-manager || true
    fi

    # Download and install NVIDIA driver
    cd /tmp
    if [ ! -f "$DRIVER_FILE" ]; then
        curl -fSLO "$DOWNLOAD_URL"
    fi
    chmod +x "$DRIVER_FILE"
    ./"$DRIVER_FILE" --silent --dkms --no-x-check --no-nouveau-check --disable-nouveau

    # Enable NVIDIA DRM modeset for Wayland
    cat << EOF > /etc/modprobe.d/nvidia.conf
options nvidia-drm modeset=1
EOF
    update-initramfs -u

    # Optionally install NVIDIA Container Toolkit
    read -p "Do you want to install NVIDIA Container Toolkit for Docker GPU support? (y/N): " install_toolkit
    if [ "$install_toolkit" = "y" ] || [ "$install_toolkit" = "Y" ]; then
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
        apt update
        apt install -y nvidia-container-toolkit

        # Configure Docker for NVIDIA runtime
        nvidia-ctk runtime configure --runtime=docker
    else
        echo "Skipping NVIDIA Container Toolkit installation."
    fi

    # Clean up
    rm -f "$DRIVER_FILE"

    unmask_docker
    echo "Installation complete."
    prompt_reboot
}

install() {
    if lsmod | grep -q nouveau; then
        echo "Nouveau driver is active. Running pre-reboot installation steps..."
        blacklist_nouveau
    else
        install_driver
    fi
}

rebuild() {
    ensure_base_tools

    apt update
    apt install -y linux-headers-$(uname -r) || {
        echo "Error: Failed to install linux-headers-$(uname -r)"
        exit 1
    }
    
    version=$(get_installed_version)
    if [ -z "$version" ]; then
        echo "Error: No NVIDIA driver installed."
        exit 1
    fi

    echo "Detected NVIDIA version: $version"
    echo
    
    echo "Cleaning stale NVIDIA DKMS versions (keeping $version)..."
    dkms status 2>/dev/null | awk -F'[, ]+' '/^nvidia\//{print $1}' | cut -d/ -f2 | sort -u | while read -r v; do
        [ -z "$v" ] && continue
        if [ "$v" != "$version" ]; then
            echo "  Removing stale DKMS entry: nvidia/$v"
            dkms remove -m nvidia -v "$v" --all || true
        fi
    done
    echo

    echo "Rebuilding NVIDIA DKMS modules for kernel $(uname -r)..."

 # Preferred path: let DKMS build what the system expects for this kernel.
    if dkms autoinstall -k "$(uname -r)"; then
        echo "DKMS autoinstall succeeded."
    else
        echo "DKMS autoinstall failed; attempting dkms reinstall for nvidia/$version..."
        # reinstall is generally safer than install --force when state is messy
        dkms reinstall -m nvidia -v "$version" -k "$(uname -r)" || {
            echo "Error: dkms reinstall failed."
            echo "Tip: check /var/lib/dkms/nvidia/$version/build/make.log"
            exit 1
        }
        echo "DKMS reinstall succeeded."
    fi

    update-initramfs -u

    if command -v nvidia-ctk &> /dev/null; then
        echo
        echo "Reconfiguring NVIDIA Container Toolkit for Docker..."
        nvidia-ctk runtime configure --runtime=docker
        prompt_restart_docker
        echo "NVIDIA Container Toolkit reconfigured."
    fi

    echo "Rebuild complete."
    echo "After reboot, verify with: sudo bash $0 --status"
    prompt_reboot
}
 

case "$1" in
  --status)
    status
    ;;
  --version)
    show_version
    ;;
  --uninstall)
    uninstall "$@"
    ;;
  --install)
    install
    ;;
  --rebuild)
    rebuild
    ;;
  *)
    display_usage
    ;;
esac
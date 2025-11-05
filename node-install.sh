#!/bin/bash

# Reader Node Installation Script
set -uo pipefail

trap 'echo ""; echo ""; echo "[WARNING] Installation cancelled by user."; exit 0' INT TERM

# Configuration
PBC_DIR="/opt/pbc-mainnet"
WORK_DIR="$HOME/pbc"
SNAPSHOT_URL="https://snapshot.partisiablockchain.com/mainnet-snapshot.zip"
NODE_REGISTER_URL="https://gitlab.com/partisiablockchain/main/-/raw/main/scripts/node-register.sh"

# User configuration
USER_NEW_USERNAME=""
USER_EXISTING_USERNAME=""
USER_EXPOSE_TCP=false
USER_SSH_PORT="22"
USER_DOWNLOAD_SNAPSHOT=true
USER_CONFIGURE_FIREWALL=true

# Runtime settings
SKIP_SNAPSHOT=false
NODE_TYPE="reader"

# Text formatting
BOLD='\033[1m'
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

# Logging
log_info()  { echo -e "${GREEN}[INFO]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC}   $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC}    $1"; }
log_bold()  { echo -e "${BOLD}$1${NC}"; }

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Partisia Blockchain Node Installation Script

OPTIONS:
    -h, --help              Show this help message
    -s, --skip-snapshot     Skip blockchain snapshot download

EXAMPLES:
    $0                      # Interactive installation
    $0 --skip-snapshot      # Installation without snapshot

EOF
    exit 0
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                ;;
            -s|--skip-snapshot)
                SKIP_SNAPSHOT=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                ;;
        esac
    done
}

# If re-run or user failed previous

check_existing_installation() {
    log_step "Checking for existing installation"
    echo "─────────────────────────────────────────────────────────────────────"

    local conflicts_detected=false

    if [[ -d "$PBC_DIR" ]]; then
        log_warn "Found existing PBC directory: $PBC_DIR"
        conflicts_detected=true
    fi

    if [[ -d "$WORK_DIR" ]]; then
        log_warn "Found existing working directory: $WORK_DIR"
        conflicts_detected=true
    fi

    if docker ps --format "table {{.Names}}" | grep -q "pbc-mainnet"; then
        log_warn "Found running PBC container: pbc-mainnet"
        conflicts_detected=true
    fi

    if docker ps -a --format "table {{.Names}}" | grep -q "pbc-mainnet"; then
        log_warn "Found existing PBC container (may be stopped): pbc-mainnet"
        conflicts_detected=true
    fi

    if [[ -f "/opt/pbc-mainnet/conf/config.json" ]]; then
        log_warn "Found existing node configuration"
        conflicts_detected=true
    fi

    if [[ "$conflicts_detected" == true ]]; then
        echo ""
        log_error "Potential conflicts detected with existing installation!"
        echo ""
        log_info "Available options:"
        log_info "1. Remove existing installation and start fresh"
        log_info "2. Continue with existing installation (may cause issues)"
        log_info "3. Cancel and resolve manually"
        echo ""

        read -p "Choose option (1/2/3) [1]: " user_choice
        user_choice=${user_choice:-1}

        case $user_choice in
            1)
                log_info "Removing existing installation..."
                docker stop pbc-mainnet 2>/dev/null || true
                docker rm pbc-mainnet 2>/dev/null || true
                sudo rm -rf "$PBC_DIR" 2>/dev/null || true
                rm -rf "$WORK_DIR" 2>/dev/null || true
                log_info "Existing installation removed"
                ;;
            2)
                log_warn "Continuing with existing installation - proceed with caution!"
                ;;
            3)
                log_info "Installation cancelled. Please resolve conflicts manually."
                exit 1
                ;;
            *)
                log_error "Invalid option selected"
                exit 1
                ;;
        esac
        echo ""
    else
        log_info "No conflicts detected - system ready for fresh installation"
        echo ""
    fi
}

cleanup_docker_repos() {
    log_info "Checking for Docker repository conflicts..."

    if find /etc/apt/sources.list.d/ -name "*docker*" 2>/dev/null | grep -q .; then
        log_warn "Found conflicting Docker repositories, cleaning up..."
        sudo rm -f /etc/apt/sources.list.d/docker*.list
        sudo rm -f /etc/apt/sources.list.d/docker*.list.save 2>/dev/null
        log_info "Conflicting Docker repositories removed"
    fi

    sudo apt-get clean
    sudo apt-get autoclean
}

configure_docker_logging() {
    log_step "Configuring Docker Log Rotation"
    echo "─────────────────────────────────────────────────────────────────────"

    local docker_config="/etc/docker/daemon.json"

    # Check if configuration already exists
    if [[ -f "$docker_config" ]] && sudo grep -q "log-opts" "$docker_config"; then
        log_info "Docker log rotation is already configured"
        return 0
    fi

    log_info "Setting up Docker log rotation (100MB max, 3 files)"

    # Create or update daemon.json
    sudo tee "$docker_config" > /dev/null << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
EOF

    if [[ $? -eq 0 ]]; then
        log_info "Docker log configuration applied successfully"

        # Reload and restart Docker
        sudo systemctl daemon-reload
        sudo systemctl restart docker

        # Wait a moment for Docker to restart
        sleep 5

        if systemctl is-active --quiet docker; then
            log_info "Docker service restarted with new log settings"
        else
            log_error "Docker failed to restart after configuration"
            return 1
        fi
    else
        log_error "Failed to configure Docker logging"
        return 1
    fi

    echo ""
}

install_docker() {
    log_info "Installing Docker using official repository..."

    sudo apt-get update
    sudo apt-get install -y ca-certificates curl

    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu   \
      $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    sudo systemctl enable docker
    sudo systemctl start docker

    # Wait a moment for Docker to start
    sleep 5

    if sudo docker run --rm hello-world &>/dev/null; then
        log_info "Docker installed successfully: $(docker --version | awk '{print $3}' | tr -d ',')"

        configure_docker_logging
        return 0
    else
        log_error "Docker installation verification failed"
        return 1
    fi
}

install_package() {
    local package_name=$1
    if dpkg -l | grep -q "^ii  $package_name "; then
        log_info "$package_name already installed"
        return 0
    fi

    log_info "Installing $package_name..."
    if sudo apt-get install -y "$package_name"; then
        log_info "$package_name installed successfully"
        return 0
    else
        log_warn "Failed to install $package_name via apt, trying alternative methods..."

        case "$package_name" in
            "jq")
                if command -v curl &> /dev/null; then
                    curl -L -o /tmp/jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64
                    sudo install /tmp/jq /usr/local/bin/jq
                    rm -f /tmp/jq
                    if command -v jq &> /dev/null; then
                        log_info "jq installed via GitHub"
                        return 0
                    fi
                fi
                ;;
        esac

        log_warn "Failed to install $package_name, but continuing..."
        return 1
    fi
}

install_required_packages() {
    log_step "Installing system dependencies"
    echo "─────────────────────────────────────────────────────────────────────"

    cleanup_docker_repos

    log_info "Updating system packages..."
    if ! sudo apt-get update; then
        log_warn "Package update encountered issues, attempting to fix..."
        sudo apt-get update --fix-missing || true
    fi

    log_info "Installing required packages..."
    local required_packages=("curl" "wget" "unzip" "jq" "htop" "ufw")
    for package in "${required_packages[@]}"; do
        install_package "$package"
    done

    if ! command -v docker &> /dev/null; then
        log_info "Docker not found, installing..."
        if install_docker; then
            log_info "Docker installation completed"
        else
            log_error "Docker installation via official method failed, trying fallback..."
            curl -fsSL https://get.docker.com -o get-docker.sh
            sudo sh get-docker.sh
            rm get-docker.sh

            sudo systemctl enable docker
            sudo systemctl start docker

            # Wait a moment for Docker to start
            sleep 5

            if sudo docker run --rm hello-world &>/dev/null; then
                log_info "Docker installed via convenience script"

                configure_docker_logging
            else
                log_error "Docker installation completely failed"
                log_error "Please install Docker manually: curl -fsSL https://get.docker.com | sh"
                exit 1
            fi
        fi
    else
        log_info "Docker already installed: $(docker --version)"

        # Configure Docker logging
        configure_docker_logging
    fi

    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        log_info "Installing Docker Compose..."
        sudo apt-get install -y docker-compose-plugin

        if ! docker compose version &> /dev/null; then
            log_info "Installing Docker Compose (standalone version)..."
            sudo curl -L "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
        fi
    fi

    if command -v docker-compose &> /dev/null; then
        log_info "Docker Compose installed: $(docker-compose --version)"
    elif docker compose version &> /dev/null; then
        log_info "Docker Compose (plugin) installed: $(docker compose version --short)"
    else
        log_error "Docker Compose installation failed"
        exit 1
    fi

    if ! groups $USER | grep -q '\bdocker\b'; then
        sudo usermod -aG docker $USER
        log_info "Added $USER to docker group"
        log_warn "Note: You may need to re-login or run 'newgrp docker' for group changes to take effect"
    fi

    log_info "All essential dependencies verified and installed"
    echo ""
}

download_blockchain_snapshot() {
    log_info "Starting blockchain snapshot download and extraction process..."
    echo ""
    log_bold "═══════════════════════════════════════════════════════════════════"
    log_bold "              SNAPSHOT DOWNLOAD IN PROGRESS"
    log_bold "═══════════════════════════════════════════════════════════════════"
    echo ""

    local remote_size=$(curl -sI "$SNAPSHOT_URL" | grep -i 'content-length' | awk '{print $2}' | tr -d '\r')
    local snapshot_size_gb=170

    if [[ -n "$remote_size" ]]; then
        snapshot_size_gb=$((remote_size / 1024 / 1024 / 1024))
        log_info "Remote snapshot size: ${snapshot_size_gb}GB (compressed)"
    else
        log_warn "Could not determine remote file size, using estimated 170GB"
    fi

    local required_space=$((snapshot_size_gb + snapshot_size_gb + 10))
    local available_space=$(df -BG --output=avail "$PBC_DIR" | tail -n 1 | sed 's/[^0-9]*//g')

    log_info "Disk Space Analysis:"
    log_info "  Snapshot file: ${snapshot_size_gb}GB (compressed)"
    log_info "  Extracted data: ${snapshot_size_gb}GB (uncompressed)"
    log_info "  Safety buffer: 10GB"
    log_info "  Total required: ${required_space}GB"
    log_info "  Available space: ${available_space}GB"
    echo ""

    if (( available_space < required_space )); then
        log_error "Insufficient disk space for snapshot download!"
        log_error "Required: ${required_space}GB, Available: ${available_space}GB"
        return 1
    fi

    log_info "Disk space verification passed"
    echo ""
    log_info "Estimated time requirements:"
    log_info "  Download: 30-90 minutes (varies with internet speed)"
    log_info "  Extraction: 10-30 minutes (varies with disk speed)"
    echo ""
    log_warn "Important: Do not interrupt this process - it will restart from the beginning if cancelled"
    echo ""
    read -p "Press Enter to begin download..." proceed

    cd "$PBC_DIR"

    log_info "Downloading blockchain snapshot..."
    log_info "Source: $SNAPSHOT_URL"
    log_info "Destination: $PBC_DIR/mainnet-snapshot.zip"
    echo ""

    local download_start=$(date +%s)

    if wget --progress=bar:force -O mainnet-snapshot.zip "$SNAPSHOT_URL"; then
        local download_end=$(date +%s)
        local download_duration=$((download_end - download_start))
        local download_minutes=$((download_duration / 60))

        echo "─────────────────────────────────────────────────────────────────────"
        log_info "Download completed successfully in ${download_minutes} minutes"
        local file_size=$(du -h mainnet-snapshot.zip | cut -f1)
        log_info "Downloaded file size: $file_size"
    else
        log_error "Snapshot download failed!"
        return 1
    fi

    log_info "Verifying snapshot integrity..."
    echo "Running integrity check: unzip -t mainnet-snapshot.zip"

    if unzip -t mainnet-snapshot.zip; then
        log_info "Snapshot verification passed"
    else
        log_error "Snapshot verification failed - file appears to be corrupted"
        rm -f mainnet-snapshot.zip
        return 1
    fi

    log_info "Extracting snapshot data..."
    log_info "This may take several minutes..."
    echo ""

    local extract_start=$(date +%s)

    if [[ "$(ls -A storage 2>/dev/null)" ]]; then
        sudo unzip -o mainnet-snapshot.zip -d "$PBC_DIR"
    else
        sudo unzip mainnet-snapshot.zip -d "$PBC_DIR"
    fi

    local extract_result=$?
    local extract_end=$(date +%s)
    local extract_duration=$((extract_end - extract_start))
    local extract_minutes=$((extract_duration / 60))

    if [[ $extract_result -eq 0 ]]; then
        log_info "Extraction completed in ${extract_minutes} minutes"
    else
        log_error "Snapshot extraction failed"
        return 1
    fi

    log_info "Cleaning up temporary files..."
    rm -f mainnet-snapshot.zip
    log_info "Removed downloaded snapshot file"

    log_info "Setting file permissions..."
    sudo chown -R "1500:1500" "$PBC_DIR"
    log_info "File ownership set to 1500:1500"

    echo ""
    log_bold "═══════════════════════════════════════════════════════════════════"
    log_bold "           SNAPSHOT INSTALLATION COMPLETED SUCCESSFULLY"
    log_bold "═══════════════════════════════════════════════════════════════════"
    log_info "Total processing time: $((download_minutes + extract_minutes)) minutes"
    log_info "Your node will synchronize much faster with the snapshot"
    echo ""

    return 0
}

show_installation_summary() {
    echo ""
    log_bold "═══════════════════════════════════════════════════════════════════"
    log_bold "                   INSTALLATION COMPLETE"
    log_bold "═══════════════════════════════════════════════════════════════════"
    echo ""
    log_info "Working directory: $WORK_DIR"
    log_info "Data directory:    $PBC_DIR"
    echo ""
    log_info "Node management commands:"
    echo "  cd $WORK_DIR"

    if command -v docker-compose &> /dev/null; then
        echo "  docker-compose up -d           # Start the node"
        echo "  docker-compose down            # Stop the node"
    elif docker compose version &> /dev/null; then
        echo "  docker compose up -d           # Start the node"
        echo "  docker compose down            # Stop the node"
    else
        echo "  docker stop pbc-mainnet        # Stop the node"
        echo "  docker start pbc-mainnet       # Start the node"
    fi

    echo "  docker logs -f pbc-mainnet       # View node logs"
    echo "  ./node-register.sh status        # Check node status"
    echo ""
    log_info "Live sync monitor command (run from $WORK_DIR):"
    cat << 'EOF'
   docker logs -f --tail=100 pbc-mainnet \
   | awk '
   function show(){
       printf "\rGov:%s  Shard0:%s  Shard1:%s  Shard2:%s   ", latest["Gov"], latest["Shard0"], latest["Shard1"], latest["Shard2"];
       fflush(stdout)
   }
   match($0, /\[BlockRequester-([A-Za-z0-9]+)-[0-9]+\]/, a) && match($0, /blockTime=([0-9]+)/, b) {
       latest[a[1]]=b[1]+0;
       show()
   }'
EOF
    echo ""
    echo ""
    log_info "Docker log rotation is configured:"
    echo "  Maximum log file size: 100MB"
    echo "  Maximum log files: 3"
    echo "  Location: /etc/docker/daemon.json"
    echo ""
    log_info "Monitoring tools:"
    echo "  htop                            # System resource monitor"
    echo "  docker stats pbc-mainnet        # Container statistics"
    echo ""
    log_warn "Recommendation:"
    log_warn "  Remove this script after installation: rm -f $(basename "$0")"
    echo ""
    log_info "Documentation: https://partisiablockchain.gitlab.io/documentation/"
    log_bold "═══════════════════════════════════════════════════════════════════"
}

main_installation() {
    echo ""
    log_bold "═══════════════════════════════════════════════════════════════════"
    log_bold "         PARTISIA BLOCKCHAIN NODE INSTALLATION WIZARD"
    log_bold "═══════════════════════════════════════════════════════════════════"
    echo ""
    log_info "Following official Partisia Blockchain documentation"
    log_info "https://partisiablockchain.gitlab.io/documentation/node-operations/run-a-reader-node.html"
    echo ""

    check_existing_installation
    install_required_packages

    log_step "System Security Configuration"
    echo "─────────────────────────────────────────────────────────────────────"
    read -p "Change the root password if this is your first time logging in. [Y/n]: " change_root_pass
    if [[ ! "$change_root_pass" =~ ^[Nn]$ ]]; then
        sudo passwd root
    fi
    echo ""

    log_step "User Account Configuration"
    echo "─────────────────────────────────────────────────────────────────────"

    if [[ $EUID -eq 0 ]]; then
        echo ""
        log_info "For security best practices, running the node as a non-root user is recommended."
        echo ""
        log_info "Available options:"
        log_info "1. Create a new non-root user account"
        log_info "2. Use an existing non-root user account"
        log_info "3. Continue as root user (not recommended)"
        echo ""

        while true; do
            read -p "Select option (1/2/3) [2]: " user_selection
            user_selection=${user_selection:-2} 

            case $user_selection in
                1|2|3)
                    break
                    ;;
                *)
                    log_error "Invalid selection. Please enter 1, 2, or 3."
                    ;;
            esac
        done
       
        case $user_selection in
            1)
                while true; do
                    read -p "Enter username for new user: " new_username
                    if [[ -z "$new_username" ]]; then
                        log_error "Username cannot be empty"
                        continue
                    fi

                    if id "$new_username" &>/dev/null; then
                        log_warn "User '$new_username' already exists"
                        read -p "Use this existing user instead? [Y/n]: " use_existing
                        if [[ ! "$use_existing" =~ ^[Nn]$ ]]; then
                            USER_EXISTING_USERNAME="$new_username"
                            break
                        else
                            log_info "Please choose a different username"
                            continue
                        fi
                    else
                        USER_NEW_USERNAME="$new_username"
                        sudo adduser "$new_username"
                        sudo usermod -aG sudo "$new_username"
                        sudo usermod -aG systemd-journal "$new_username"
                        sudo usermod -aG docker "$new_username"
                        log_info "User $new_username created with appropriate permissions"
                        USER_EXISTING_USERNAME="$new_username"
                        break
                    fi
                done
                ;;
            2)
                while true; do
                    read -p "Enter existing username: " existing_user
                    if [[ -z "$existing_user" ]]; then
                        log_error "Username cannot be empty"
                        continue
                    fi

                    if [[ "$existing_user" =~ ^[123]$ ]]; then
                        log_error "Input '$existing_user' is not a valid username. Please enter an existing username."
                        continue
                    fi

                    if id "$existing_user" &>/dev/null; then
                        USER_EXISTING_USERNAME="$existing_user"
                        sudo usermod -aG docker "$existing_user" 2>/dev/null || true
                        log_info "Using existing user: $existing_user"
                        break
                    else
                        log_error "User '$existing_user' does not exist"
                        read -p "Try another username? [Y/n]: " retry_user
                        if [[ "$retry_user" =~ ^[Nn]$ ]]; then
                            log_info "Exiting due to non-existent user."
                            exit 1 
                        fi
                        
                    fi
                done
                ;;
            3)
                log_warn "Proceeding with root user - security considerations apply"
                ;;
            
            *)
                log_error "Unexpected selection. This should not happen."
                exit 1
                ;;
        esac
    else
        USER_EXISTING_USERNAME="$USER"
        log_info "Running as non-root user: $USER"
    fi

    if [[ -n "$USER_EXISTING_USERNAME" ]] && [[ "$USER_EXISTING_USERNAME" != "root" ]]; then
        WORK_DIR="/home/$USER_EXISTING_USERNAME/pbc"
    else
        WORK_DIR="$HOME/pbc"
    fi

    echo ""
    log_info "Installation Configuration Summary:"
    log_info "  Current user: $USER"
    log_info "  Node owner: ${USER_EXISTING_USERNAME:-$USER}"
    log_info "  Working directory: $WORK_DIR"
    log_info "  Blockchain data: $PBC_DIR"
    echo ""

    log_step "System Monitoring Setup"
    echo "─────────────────────────────────────────────────────────────────────"
    if command -v htop &> /dev/null; then
        log_info "htop system monitor is available"
    else
        log_warn "htop not installed (optional for system monitoring)"
    fi
    echo ""

    log_step "Firewall Configuration"
    echo "─────────────────────────────────────────────────────────────────────"
    log_info "Configuring firewall for required ports (9888-9897, 8080) and SSH."

    read -p "Enter SSH port (default 22): " ssh_port_input
    ssh_port_input=${ssh_port_input:-22}

    sudo ufw disable
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow "$ssh_port_input/tcp"
    sudo ufw allow 9888:9897/tcp

    read -p "Expose TCP reader ports (9938-9947) for Execution Engine? [y/N]: " expose_tcp_ports
    if [[ "$expose_tcp_ports" =~ ^[Yy]$ ]]; then
        sudo ufw allow 9938:9947/tcp
    fi

    sudo ufw limit "$ssh_port_input/tcp"
    sudo ufw logging on
    sudo ufw enable
    log_info "Firewall configuration applied:"
    sudo ufw status
    echo ""

    log_step "Creating Node Directory Structure"
    echo "─────────────────────────────────────────────────────────────────────"
    sudo mkdir -p "$PBC_DIR/conf"
    sudo mkdir -p "$PBC_DIR/storage"
    log_info "Created configuration and storage directories"
    echo ""

    if [[ "$SKIP_SNAPSHOT" != "true" ]]; then
        log_step "Blockchain Snapshot Configuration"
        echo "─────────────────────────────────────────────────────────────────────"

        log_info "Checking snapshot requirements..."
        local snapshot_size=$(curl -sI "$SNAPSHOT_URL" | grep -i 'content-length' | awk '{print $2}' | tr -d '\r')
        local estimated_size_gb=170

        if [[ -n "$snapshot_size" ]]; then
            estimated_size_gb=$((snapshot_size / 1024 / 1024 / 1024))
            log_info "Snapshot size: ${estimated_size_gb}GB (compressed)"
        else
            log_warn "Could not determine snapshot size, using estimate: 170GB"
        fi

        local total_required=$((estimated_size_gb + estimated_size_gb + 10))
        local available_disk=$(df -BG --output=avail "$PBC_DIR" | tail -n 1 | sed 's/[^0-9]*//g')

        echo ""
        log_info "Storage Requirements Analysis:"
        log_info "  Snapshot download: ${estimated_size_gb}GB"
        log_info "  Extracted data: ${estimated_size_gb}GB"
        log_info "  Safety margin: 10GB"
        log_info "  Total required: ${total_required}GB"
        log_info "  Available space: ${available_disk}GB"
        echo ""

        if (( available_disk < total_required )); then
            log_error "Insufficient disk space for snapshot installation!"
            log_error "Required: ${total_required}GB, Available: ${available_disk}GB"
            echo ""
            log_info "Available choices:"
            log_info "1. Free up disk space and retry"
            log_info "2. Continue without snapshot (sync from genesis)"
            log_info "3. Use different storage location"
            echo ""

            read -p "Continue without snapshot? [Y/n]: " skip_snapshot_choice
            if [[ ! "$skip_snapshot_choice" =~ ^[Nn]$ ]]; then
                log_info "Skipping snapshot - node will sync from genesis block"
                USER_DOWNLOAD_SNAPSHOT=false
            else
                log_info "Please free up disk space and restart installation"
                exit 1
            fi
        else
            log_info "Disk space verification successful"
            echo ""
            log_info "Snapshot advantages:"
            log_info "  • Faster synchronization (hours instead of days)"
            log_info "  • Reduced network bandwidth usage"
            log_info "  • Lower network load"
            echo ""
            log_warn "Snapshot considerations:"
            log_warn "  • If block production node and you have enough time, consider syncing from scratch."
            log_warn "  • Large download: ${estimated_size_gb}GB"
            log_warn "  • Time required: 30-90 minutes download, 10-30 minutes extraction"
            echo ""

            read -p "Download and install blockchain snapshot? [Y/n]: " install_snapshot
            if [[ ! "$install_snapshot" =~ ^[Nn]$ ]]; then
                download_blockchain_snapshot
            else
                log_info "Skipping snapshot - full sync from genesis will be required"
                log_warn "This process may take several days to complete, go touch grass."
                USER_DOWNLOAD_SNAPSHOT=false
            fi
        fi
        echo ""
    else
        log_info "Snapshot download skipped (user requested)"
        echo ""
        log_warn "Node will perform full synchronization from genesis block"
        log_warn "This process may take several days to complete, go touch grass."
        echo ""
    fi

    log_step "Configuring File Permissions"
    echo "─────────────────────────────────────────────────────────────────────"
    sudo chown -R "1500:1500" "$PBC_DIR"
    sudo chmod 500 "$PBC_DIR/conf"
    sudo chmod 700 "$PBC_DIR/storage"
    log_info "File permissions configured for container user"
    echo ""

    log_step "Creating Docker Configuration"
    echo "─────────────────────────────────────────────────────────────────────"

    sudo mkdir -p "$WORK_DIR"

    if [[ -n "$USER_EXISTING_USERNAME" ]] && [[ "$USER_EXISTING_USERNAME" != "$USER" ]]; then
        sudo chown -R "$USER_EXISTING_USERNAME:$USER_EXISTING_USERNAME" "$WORK_DIR"
        sudo -u "$USER_EXISTING_USERNAME" mkdir -p "$WORK_DIR"
    else
        mkdir -p "$WORK_DIR"
    fi

    cd "$WORK_DIR"

    cat > docker-compose.yml << 'EOF'
services:
  pbc:
    image: registry.gitlab.com/partisiablockchain/mainnet:latest
    container_name: pbc-mainnet
    user: "1500:1500"
    restart: always
    ports:
      - "9888-9897:9888-9897"
      - "8080:8080"
    command: ["/conf/config.json", "/storage/"]
    volumes:
      - /opt/pbc-mainnet/conf:/conf
      - /opt/pbc-mainnet/storage:/storage
    environment:
      - JAVA_TOOL_OPTIONS="-Xmx8G"
EOF

    log_info "Docker Compose configuration created"
    echo ""

    log_step "Downloading Node Registration Tool"
    echo "─────────────────────────────────────────────────────────────────────"
    curl -sL "$NODE_REGISTER_URL" -o node-register.sh
    chmod +x node-register.sh
    log_info "Node registration script downloaded and prepared"
    echo ""

    log_step "Node Configuration Setup"
    echo "─────────────────────────────────────────────────────────────────────"
    echo ""
    log_info "To configure your node, you need peers information."
    log_info "Peer format: networkPublicKey:ip:port"
    echo ""
    log_info "You can find peers from:"
    log_info "• Partisia Blockchain Discord community"
    echo ""
    log_warn "The configuration tool will now run interactively."
    log_warn "You will be prompted to enter peers."
    log_warn "Press Enter with no input when you have added all peers."
    echo ""
    read -p "Press Enter to begin node configuration...and wait a moment..." start_config

   
    trap - INT TERM
    ./node-register.sh create-config
    #trap
    trap 'echo ""; echo ""; echo "[WARNING] Installation cancelled by user."; exit 0' INT TERM

    if [[ -f "$PBC_DIR/conf/config.json" ]]; then
        log_info "Node configuration file created successfully"

        if command -v jq &> /dev/null; then
            local node_key=$(jq -r '.networkKey' "$PBC_DIR/conf/config.json" 2>/dev/null)
            if [[ -n "$node_key" ]] && [[ "$node_key" != "null" ]]; then
                echo ""
                log_bold "═══════════════════════════════════════════════════════════════════"
                log_bold "               YOUR NODE NETWORK IDENTIFIER"
                log_bold "═══════════════════════════════════════════════════════════════════"
                echo "$node_key"
                log_bold "═══════════════════════════════════════════════════════════════════"
                log_info "For reference"
                log_info "You can use the node-register.sh tool's to get the configuration of this node with ./node-register.sh get-config"
                echo ""
            fi
        fi
    else
        log_error "Configuration file was not created"
        log_info "You can run the configuration manually: ./node-register.sh create-config"
    fi
    echo ""

    log_step "Starting Blockchain Node"
    echo "─────────────────────────────────────────────────────────────────────"
    read -p "Start the node now? [Y/n]: " launch_node
    if [[ ! "$launch_node" =~ ^[Nn]$ ]]; then
        if command -v docker-compose &> /dev/null; then
            docker-compose up -d
        else
            docker compose up -d
        fi

        sleep 5

        if docker ps | grep -q pbc-mainnet; then
            log_info "Node started successfully and is now running"
            echo ""

            #container status
            log_info "1. Container Status:"
            docker ps --filter "name=pbc-mainnet" --format "table {{.Names}}\t{{.Status}}"

            while true; do
                echo ""
                log_info "Node is running. What would you like to do next?"
                echo "  a) View recent logs (last 50 lines)"
                echo "  b) Monitor live sync progress (shows block times per shard - press Ctrl+C to return)"
                echo "  c) Exit and manage later"
                echo ""
                read -p "Choose an option (a/b/c) [c]: " log_choice
                log_choice=${log_choice:-c} 

                case $log_choice in
                    [Aa]*)
                        echo ""
                        log_info "Recent logs (last 100 lines):"
                        docker logs --tail 100 pbc-mainnet
                        echo "" 
                        ;;

                    [Bb]*)
                        echo ""
                        log_info "Live sync shows number of blocks synced per shard.Some shards are slower then others"
                        log_info "Starting live sync monitor (Press Ctrl+C *while it's running* to stop and return to the menu)..."
                       
                        trap - INT TERM
                        
                        docker logs -f --tail=100 pbc-mainnet 2>/dev/null \
                        | awk '
                            BEGIN {
                                
                                latest["Gov"] = "N/A"
                                latest["Shard0"] = "N/A"
                                latest["Shard1"] = "N/A"
                                latest["Shard2"] = "N/A"
                            }
                            function show() {
                                printf "\r%-12s Gov:%-10s Shard0:%-10s Shard1:%-10s Shard2:%-10s", "Syncing:", latest["Gov"], latest["Shard0"], latest["Shard1"], latest["Shard2"]
                                fflush()
                            }
                            
                            match($0, /\[BlockRequester-([A-Za-z0-9]+)-[0-9]+\]/, a) && match($0, /blockTime=([0-9]+)/, b) {
                                # Use the captured identifier (a[1]) as the key
                                key = a[1]
                                value = b[1] + 0                           
                                latest[key] = value                              
                                show()
                            }
                        '
    
                        trap 'echo ""; echo ""; echo "[WARNING] Installation cancelled by user."; exit 0' INT TERM
                       
                        local awk_status=$?
                        if [[ $awk_status -eq 130 || $awk_status -eq 143 ]]; then
                            echo "" 
                            log_info "Monitor stopped by user (Ctrl+C). Returning to menu..." 
                        else
                           echo "" 
                           log_info "Monitor finished or logs ended. Returning to menu..."
                        fi
                        
                        ;;

                    [Cc]*)
                        log_info "Exiting options menu."
                        break 
                        ;;
                    *)
                        log_warn "Invalid option '$log_choice'. Please choose a, b, or c."
                       
                        ;;
                esac
            done 

        else
            log_error "Node failed to start"
            log_info "Check logs with: docker logs pbc-mainnet"
        fi
    fi

    show_installation_summary
}


SKIP_SNAPSHOT=false
parse_arguments "$@"
main_installation

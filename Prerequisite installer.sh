#!/bin/bash

LOGFILE="/var/log/setup_script.log"

# Function to log messages
log_message() {
    echo "$(date +"%Y-%m-%d %T") - $1" | tee -a "$LOGFILE"
}

# Function to check if the user is root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_message "Please run this script as root."
        exit 1
    fi
}

# Step 1: Install tools
install_tools() {
    log_message "Installing required tools..."
    apt update && apt install -y net-tools git iw docker.io python3.10-venv \
    make cmake gcc libgmp-dev libelf-dev zlib1g-dev libjansson-dev || {
        log_message "Failed to install required tools."
        exit 1
    }
}

# Step 2: Detect and configure network interfaces
configure_network_interfaces() {
    log_message "Detecting network interfaces..."

    # Get wireless interfaces
    wireless_interfaces=$(iw dev | grep Interface | awk '{print $2}')
    if [ -z "$wireless_interfaces" ]; then
        log_message "No wireless interfaces detected."
        exit 1
    fi

    # Get Ethernet interfaces (excluding loopback, wireless, and virtual interfaces)
    ethernet_interfaces=$(ls /sys/class/net | grep -E '^e')
    if [ -z "$ethernet_interfaces" ]; then
        log_message "No valid Ethernet interfaces detected."
        exit 1
    fi

    # Select wireless interface
    while true; do
        echo "Available wireless interfaces: $wireless_interfaces"
        read -p "Which wireless interface do you want to use for the hotspot? " wireless_interface

        if echo "$wireless_interfaces" | grep -qw "$wireless_interface"; then
            break
        else
            log_message "Invalid wireless interface selected. Please try again."
        fi
    done

    ip link set "$wireless_interface" down
    ip link set "$wireless_interface" name wlan0
    ip link set wlan0 up

    # Select Ethernet interface
    while true; do
        echo "Available Ethernet interfaces: $ethernet_interfaces"
        read -p "Which Ethernet interface do you want to use for the coordinator? " ethernet_interface

        if echo "$ethernet_interfaces" | grep -qw "$ethernet_interface"; then
            break
        else
            log_message "Invalid Ethernet interface selected. Please try again."
        fi
    done

    ip link set "$ethernet_interface" down
    ip link set "$ethernet_interface" name eth0
    ip link set eth0 up
}

# Step 3: Create the access point (with retries)
create_access_point() {
    log_message "Creating access point..."
    retry_count=0
    max_retries=5
    success=false

    while [ $retry_count -lt $max_retries ]; do
        nmcli con delete Hotspot 2>/dev/null  # Delete any previous connection with the same name
        nmcli con add type wifi ifname wlan0 con-name Hotspot autoconnect yes ssid R1AP &&
        nmcli con modify Hotspot 802-11-wireless.mode ap 802-11-wireless.band bg ipv4.method shared &&
        nmcli con modify Hotspot wifi-sec.key-mgmt wpa-psk &&
        nmcli con modify Hotspot wifi-sec.psk "123456123" &&
        systemctl restart NetworkManager &&
        nmcli con up Hotspot && {
            log_message "Hotspot successfully created!"
            success=true
            break
        }

        log_message "Failed to create the access point. Retrying in 5 seconds... ($((retry_count+1))/$max_retries)"
        sleep 5
        ((retry_count++))
    done

    if [ "$success" = false ]; then
        log_message "Failed to create the access point after multiple attempts. Exiting..."
        exit 1
    fi
}


# Step 4: Download the program from GitHub
download_program() {
    log_message "Downloading the program from GitHub..."
    git clone https://github.com/zoxerus/smartedge.git /home/$SUDO_USER/smartedge || {
        log_message "Failed to clone the repository."
        exit 1
    }
    cd /home/$SUDO_USER/smartedge || { log_message "Failed to enter the smartedge directory."; exit 1; }
    git fetch --all &&
    git checkout dockerising &&
    git pull origin dockerising || {
        log_message "Failed to checkout the required branch."
        exit 1
    }
    chown -R $SUDO_USER:$SUDO_USER /home/$SUDO_USER/smartedge
}

# Step 5: Create a virtual environment
create_virtual_env() {
    log_message "Creating a Python virtual environment..."
    apt install -y python3.10-venv || { log_message "Failed to install python3.10-venv."; exit 1; }
    cd /home/$SUDO_USER/smartedge
    python3 -m venv .venv &&
    source .venv/bin/activate &&
    pip install psutil aenum cassandra-driver || {
        log_message "Failed to install Python dependencies."
        exit 1
    }
    deactivate
}

# Step 6: Download Cassandra Docker image and create a network
setup_cassandra() {
    log_message "Setting up Cassandra..."
    docker pull cassandra:latest &&
    docker network create cassandra || {
        log_message "Failed to set up Cassandra."
        exit 1
    }
}

# Step 7: Download and install NIKSS software
install_nikss() {
    log_message "Installing NIKSS software..."
    apt install -y make cmake gcc git libgmp-dev libelf-dev zlib1g-dev libjansson-dev &&
    git clone --recursive https://github.com/NIKSS-vSwitch/nikss.git /home/$SUDO_USER/nikss || {
        log_message "Failed to clone NIKSS."
        exit 1
    }
    cd /home/$SUDO_USER/nikss
    ./build_libbpf.sh &&
    mkdir build && cd build &&
    cmake .. &&
    make -j$(nproc) &&
    make install &&
    ldconfig || {
        log_message "Failed to install NIKSS."
        exit 1
    }
}

# Step 8: Download BMv2 Docker image and rename it
setup_bmv2() {
    log_message "Setting up BMv2..."
    docker pull p4lang/behavioral-model &&
    docker tag p4lang/behavioral-model bmv2se:latest || {
        log_message "Failed to download and tag BMv2."
        exit 1
    }
}

# Main script execution
main() {
    check_root
    install_tools
    configure_network_interfaces
    create_access_point
    download_program
    create_virtual_env
    setup_cassandra
    install_nikss
    setup_bmv2
    log_message "Setup completed successfully!"
}

main

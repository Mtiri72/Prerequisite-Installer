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

# Function to install required tools
install_tools() {
    log_message "Installing required tools..."
    apt update && apt install -y net-tools git iw docker.io python3.10-venv \
    make cmake gcc libgmp-dev libelf-dev zlib1g-dev libjansson-dev rfkill || {
        log_message "Failed to install required tools."
        exit 1
    }
}

# Function to detect and configure network interfaces
configure_network_interfaces() {
    log_message "Detecting network interfaces..."

    # Get all available network interfaces
    interfaces=($(ls /sys/class/net))

    if [ ${#interfaces[@]} -eq 0 ]; then
        log_message "No valid network interfaces detected. Exiting."
        exit 1
    fi

    # Display numbered list of interfaces
    echo "Available network interfaces:"
    for i in "${!interfaces[@]}"; do
        echo "$((i+1)). ${interfaces[i]}"
    done

    # Select Ethernet interface
    while true; do
        read -p "Select the Ethernet interface for the coordinator (enter number): " eth_choice
        if [[ "$eth_choice" =~ ^[0-9]+$ ]] && (( eth_choice >= 1 && eth_choice <= ${#interfaces[@]} )); then
            ethernet_interface="${interfaces[eth_choice-1]}"
            break
        else
            echo "Invalid choice. Please enter a valid number."
        fi
    done

    ip link set "$ethernet_interface" down
    ip link set "$ethernet_interface" name eth0
    ip link set eth0 up

    # If AP Manager is selected, choose Wireless interface
    if [ "$PROGRAM" == "AP Manager" ]; then
        while true; do
            read -p "Select the wireless interface for the hotspot (enter number): " wifi_choice
            if [[ "$wifi_choice" =~ ^[0-9]+$ ]] && (( wifi_choice >= 1 && wifi_choice <= ${#interfaces[@]} )); then
                wireless_interface="${interfaces[wifi_choice-1]}"
                break
            else
                echo "Invalid choice. Please enter a valid number."
            fi
        done

        # Ensure wlan0 is up before setting up the hotspot
        sudo rfkill unblock wifi
        sudo ip link set "$wireless_interface" up

        # Check if the selected interface supports AP mode
        if iw list | awk '/Supported interface modes:/,/software interface modes/' | grep -qw "AP"; then
            log_message "$wireless_interface supports AP mode."
            ip link set "$wireless_interface" down
            ip link set "$wireless_interface" name wlan0
            ip link set wlan0 up
        else
            log_message "Error: Selected wireless interface does not support AP mode. Exiting."
            exit 1
        fi
    fi
}

# Function to create the access point
create_access_point() {
    if [ "$PROGRAM" != "AP Manager" ]; then return; fi
    log_message "Creating access point..."

    retry_count=0
    max_retries=5
    success=false

    while [ $retry_count -lt $max_retries ]; do
        # Ensure wlan0 is managed and up
        sudo nmcli device set wlan0 managed yes
        sudo rfkill unblock wifi
        sudo ip link set wlan0 up
        sleep 1

        # Delete previous hotspot configurations
        nmcli connection delete Hotspot 2>/dev/null
        nmcli connection delete ManualHotspot 2>/dev/null

        # Create a new hotspot
        nmcli connection add type wifi ifname wlan0 con-name Hotspot autoconnect yes ssid R1AP &&
        nmcli connection modify Hotspot 802-11-wireless.mode ap 802-11-wireless.band bg ipv4.method shared &&
        nmcli connection modify Hotspot wifi-sec.key-mgmt wpa-psk &&
        nmcli connection modify Hotspot wifi-sec.psk "123456123" &&
        nmcli connection modify Hotspot connection.interface-name wlan0

        systemctl restart NetworkManager
        sleep 2

        nmcli connection up Hotspot && {
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

# Function to download the program from GitHub
download_program() {
    log_message "Downloading the program from GitHub..."
    git clone https://github.com/zoxerus/smartedge.git /home/$SUDO_USER/smartedge || {
        log_message "Failed to clone the repository."
        exit 1
    }
}

# Function to create a virtual environment
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

# Function to setup BMv2
setup_bmv2() {
    log_message "Setting up BMv2..."
    docker pull p4lang/behavioral-model &&
    docker tag p4lang/behavioral-model bmv2se:latest || {
        log_message "Failed to download and tag BMv2."
        exit 1
    }
}

# Main function to execute the setup
main() {
    check_root
    log_message "Welcome to the Swarm Setup Script"
    echo "========================================="
    echo "   Welcome to the Swarm Setup Script    "
    echo "========================================="
    echo "Please ensure your device is connected to the internet."
    read -p "Press Enter to continue..."

    # Detect system architecture
    ARCH=$(uname -m)
    log_message "System architecture $ARCH detected."
    echo "System architecture: $ARCH"

    # Prompt user to select a program
    echo "What program do you want to setup on this machine?"
    echo "1) Coordinator"
    echo "2) AP Manager"
    echo "3) SN Manager"
    read -p "Enter your choice (1/2/3): " choice

    case $choice in
        1) PROGRAM="Coordinator";;
        2) PROGRAM="AP Manager";;
        3) PROGRAM="SN Manager";;
        *) log_message "Invalid choice. Exiting."; exit 1;;
    esac

    log_message "Selected program: $PROGRAM"

    install_tools
    configure_network_interfaces

    if [ "$PROGRAM" == "AP Manager" ]; then
        create_access_point
        download_program
        create_virtual_env
        setup_bmv2
    elif [ "$PROGRAM" == "Coordinator" ]; then
        download_program
        create_virtual_env
        setup_bmv2
    elif [ "$PROGRAM" == "SN Manager" ]; then
        download_program
        create_virtual_env
    fi

    log_message "Setup for $PROGRAM completed successfully!"
}

main

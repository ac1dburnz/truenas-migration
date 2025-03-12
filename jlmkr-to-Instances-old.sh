#!/bin/bash

# Configuration
CONFIG_FILE="$HOME/.migration_config"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Read-only operations on source
SAFE_RSYNC_OPTS="--archive --hard-links --acls --xattrs --one-file-system --no-inc-recursive --stats"

# Initialize configuration
init_config() {
    echo -e "${YELLOW}Initial configuration required:${NC}"
    read -p "Enter Jailmaker base directory (default: /mnt/jailmaker): " JAILMAKER_BASE
    JAILMAKER_BASE=${JAILMAKER_BASE:-/mnt/jailmaker}
    
    read -p "Enter mount point base directory (default: /mnt/truenas): " MOUNTED_BASE
    MOUNTED_BASE=${MOUNTED_BASE:-/mnt/truenas}
    
    read -p "Enter ZFS dataset base path (e.g., pool/.ix-virt/containers): " ZFS_DATASET_BASE
    while [[ -z "$ZFS_DATASET_BASE" ]]; do
        echo -e "${RED}ZFS dataset base path is required!${NC}"
        read -p "Enter ZFS dataset base path: " ZFS_DATASET_BASE
    done

    cat > "$CONFIG_FILE" <<EOL
JAILMAKER_BASE='$JAILMAKER_BASE'
MOUNTED_BASE='$MOUNTED_BASE'
ZFS_DATASET_BASE='$ZFS_DATASET_BASE'
EOL
}

# Load configuration or initialize
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        init_config
        source "$CONFIG_FILE"
    fi
}

# Safety validation
validate_environment() {
    local instance_name=$1
    local source_path="$JAILMAKER_BASE/${instance_name}/rootfs/"

    # Validate source integrity
    if [ ! -d "$source_path" ]; then
        echo -e "${RED}Source path '$source_path' does not exist!${NC}"
        return 1
    fi

    # Check source filesystem mount options
    local source_mount=$(findmnt -T "$source_path" -o OPTIONS -n)
    if [[ "$source_mount" == *rw* ]]; then
        echo -e "${YELLOW}Warning: Source filesystem is mounted read-write${NC}"
        read -p "Continue anyway? (y/N) " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return 1
    fi

    return 0
}

# Network configuration setup
configure_network() {
    local destination_path=$1
    
    echo -e "${YELLOW}Network Configuration:${NC}"
    read -p "Enter IP address (CIDR format, e.g., 192.168.2.20/24): " ip_address
    read -p "Enter gateway address: " gateway

    cat > "$destination_path/etc/systemd/network/eth0.network" <<EOL
[Match]
Name=eth0

[Network]
DHCP=false
Address=$ip_address
Gateway=$gateway
IPv6AcceptRA=true

[DHCPv4]
UseDomains=true

[DHCP]
ClientIdentifier=mac
EOL

    # Clean up legacy network config
    rm -f "$destination_path/etc/systemd/network/80-container-host0.network"
    
    # DNS configuration
    echo "nameserver 1.1.1.1" > "$destination_path/etc/resolv.conf"
    echo "nameserver 8.8.8.8" >> "$destination_path/etc/resolv.conf"
    
    # Systemd-resolved configuration
    if [ -f "$destination_path/etc/systemd/resolved.conf" ]; then
        sed -i '/^DNS=/d' "$destination_path/etc/systemd/resolved.conf"
        echo "DNS=1.1.1.1 8.8.8.8" >> "$destination_path/etc/systemd/resolved.conf"
    fi
}

# Target-only operations
update_systemd_services() {
    local source="$1"
    local destination="$2"
    
    echo -e "${YELLOW}Updating systemd services...${NC}"
    rsync -aHAX --ignore-existing \
        "$source/etc/systemd/system/multi-user.target.wants/" \
        "$destination/etc/systemd/system/multi-user.target.wants/"
}

# Enhanced migration function with name mapping
perform_safe_migration() {
    local source_name=$1
    local dest_name=$2
    local source_path="$JAILMAKER_BASE/${source_name}/rootfs/"
    local mount_point="$MOUNTED_BASE/${dest_name}"
    local destination_path="${mount_point}/rootfs/"
    local zfs_dataset="$ZFS_DATASET_BASE/${dest_name}"

    # Create temporary mount point
    mkdir -p "$mount_point" || {
        echo -e "${RED}Failed to create mount point!${NC}"
        return 1
    }

    # Mount target dataset read-write
    if ! mount -t zfs "$zfs_dataset" "$mount_point"; then
        echo -e "${RED}Failed to mount ZFS dataset!${NC}"
        return 1
    fi

    # Create destination structure (preserve existing)
    mkdir -p "$destination_path"

    # Perform read-only verification first
    echo -e "${YELLOW}Performing dry-run verification...${NC}"
    if ! rsync $SAFE_RSYNC_OPTS --dry-run --delete \
        --exclude=/etc/systemd/network/80-container-host0.network \
        "$source_path" "$destination_path"; then
        echo -e "${RED}Dry-run failed! Aborting migration.${NC}"
        return 1
    fi

    # Actual migration with progress
    echo -e "${YELLOW}Starting safe migration...${NC}"
    rsync $SAFE_RSYNC_OPTS --progress --delete \
        --exclude=/etc/systemd/network/80-container-host0.network \
        "$source_path" "$destination_path" || {
        echo -e "${RED}Migration failed during file copy!${NC}"
        return 1
    }

    # Network configuration (target only)
    configure_network "$destination_path"

    # Systemd services update (target only)
    update_systemd_services "$source_path" "$destination_path"

    # Final verification
    echo -e "${YELLOW}Verifying migration integrity...${NC}"
    local diff_result=$(diff -rq "$source_path" "$destination_path")
    if [ -n "$diff_result" ]; then
        echo -e "${RED}Verification failed! Differences detected:${NC}"
        echo "$diff_result"
        return 1
    fi

    # Cleanup
    umount "$mount_point" && rmdir "$mount_point"
}

# Updated main menu with name mapping
main_menu() {
    while true; do
        echo -e "\n${GREEN}TrueNAS Jailmaker Safe Migration Tool${NC}"
        echo "1) Migrate an instance"
        echo "2) Modify configuration"
        echo "3) Exit"
        read -p "Enter choice: " choice

        case $choice in
            1)
                read -p "Enter source instance name: " source_name
                if validate_environment "$source_name"; then
                    # Get destination name
                    read -p "Use same name for destination? [y/N] " same_name
                    if [[ "$same_name" =~ ^[Yy]$ ]]; then
                        dest_name="$source_name"
                    else
                        read -p "Enter destination instance name: " dest_name
                        while [[ -z "$dest_name" ]]; do
                            echo -e "${RED}Destination name cannot be empty!${NC}"
                            read -p "Enter destination instance name: " dest_name
                        done
                    fi

                    # Validate destination dataset
                    local dest_dataset="$ZFS_DATASET_BASE/${dest_name}"
                    if ! zfs list "$dest_dataset" >/dev/null 2>&1; then
                        echo -e "${RED}Destination ZFS dataset '$dest_dataset' does not exist!${NC}"
                        continue
                    fi

                    # Double confirmation
                    read -p "Migrate ${source_name} to ${dest_name}? [y/N] " confirm
                    [[ "$confirm" =~ ^[Yy]$ ]] || continue
                    
                    echo -e "${YELLOW}Stopping source instance...${NC}"
                    jlmkr stop "$source_name" 2>/dev/null
                    
                    perform_safe_migration "$source_name" "$dest_name" && \
                        echo -e "${GREEN}Migration completed successfully!${NC}" || \
                        echo -e "${RED}Migration failed!${NC}"
                fi
                ;;
            2)
                init_config
                echo -e "${GREEN}Configuration updated!${NC}"
                ;;
            3)
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice!${NC}"
                ;;
        esac
    done
}

# Trap for clean exit
trap 'echo -e "${RED}Aborted!${NC}"; exit 1' SIGINT

# Start script
load_config
main_menu

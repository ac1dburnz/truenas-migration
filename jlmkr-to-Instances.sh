#!/bin/bash

# Configuration
CONFIG_FILE="$HOME/.migration_config"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Enhanced rsync options with exclusions
SAFE_RSYNC_OPTS=(
    --archive
    --hard-links
    --acls
    --xattrs
    --one-file-system
    --no-inc-recursive
    --stats
    --delete
    --exclude=/etc/systemd/network/80-container-host0.network
    --exclude=/etc/systemd/resolved.conf
    --exclude=/var/lib/docker
    --exclude=/var/lib/apt/lists
    --exclude=*.swp
    --exclude=*.tmp
)

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

# Enhanced safety validation
validate_environment() {
    local instance_name=$1
    local source_path="$JAILMAKER_BASE/${instance_name}/rootfs/"

    if [ ! -d "$source_path" ]; then
        echo -e "${RED}Source path '$source_path' does not exist!${NC}"
        return 1
    fi

    if ! zfs list "$ZFS_DATASET_BASE/${instance_name}" >/dev/null 2>&1; then
        echo -e "${RED}Destination dataset doesn't exist!${NC}"
        return 1
    fi

    return 0
}

# Network configuration with validation
configure_network() {
    local destination_path=$1
    
    echo -e "${YELLOW}Network Configuration:${NC}"
    while true; do
        read -p "Enter IP address (CIDR format, e.g., 192.168.2.20/24): " ip_address
        [[ "$ip_address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && break
        echo -e "${RED}Invalid IP format!${NC}"
    done

    while true; do
        read -p "Enter gateway address: " gateway
        [[ "$gateway" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        echo -e "${RED}Invalid gateway format!${NC}"
    done

    mkdir -p "$destination_path/etc/systemd/network"
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

    # Cleanup legacy network config
    rm -f "$destination_path/etc/systemd/network/80-container-host0.network"
    
    # DNS configuration
    echo "nameserver 1.1.1.1" > "$destination_path/etc/resolv.conf"
    echo "nameserver 8.8.8.8" >> "$destination_path/etc/resolv.conf"
    
    # Systemd-resolved handling
    if [ -f "$destination_path/etc/systemd/resolved.conf" ]; then
        sed -i '/^DNS=/d' "$destination_path/etc/systemd/resolved.conf"
        echo "DNS=1.1.1.1 8.8.8.8" >> "$destination_path/etc/systemd/resolved.conf"
    fi
}

# Service synchronization with improved excludes
update_systemd_services() {
    local source="$1"
    local destination="$2"
    
    echo -e "${YELLOW}Updating systemd services...${NC}"
    rsync -aHAX --ignore-existing \
        --exclude=snapd.* \
        --exclude=cloud-* \
        "$source/etc/systemd/system/multi-user.target.wants/" \
        "$destination/etc/systemd/system/multi-user.target.wants/"
}

# Migration core with enhanced error handling
perform_safe_migration() {
    local source_name=$1
    local dest_name=$2
    local source_path="$JAILMAKER_BASE/${source_name}/rootfs/"
    local mount_point="$MOUNTED_BASE/${dest_name}"
    local destination_path="${mount_point}/rootfs/"
    local zfs_dataset="$ZFS_DATASET_BASE/${dest_name}"

    # Create temporary mount
    mkdir -p "$mount_point" || {
        echo -e "${RED}Failed to create mount point!${NC}"
        return 1
    }

    # Mount ZFS dataset
    if ! mount -t zfs "$zfs_dataset" "$mount_point"; then
        echo -e "${RED}Failed to mount ZFS dataset!${NC}"
        rm -rf "$mount_point"
        return 1
    fi

    # Migration process
    (
        set -eo pipefail
        echo -e "${YELLOW}Starting dry run...${NC}"
        rsync "${SAFE_RSYNC_OPTS[@]}" --dry-run "$source_path" "$destination_path"
        
        echo -e "${YELLOW}\nPerforming actual migration...${NC}"
        rsync "${SAFE_RSYNC_OPTS[@]}" --progress "$source_path" "$destination_path"
        
        configure_network "$destination_path"
        update_systemd_services "$source_path" "$destination_path"
    ) || {
        echo -e "${RED}Migration failed!${NC}"
        umount "$mount_point" && rmdir "$mount_point"
        return 1
    }

    # Verification with intelligent filtering
    echo -e "${YELLOW}Verifying migration...${NC}"
    local diff_filter='grep -vE "special file|No such file|recursive directory loop"'
    local diff_output=$(diff -rq \
        --exclude=/etc/systemd/network/80-container-host0.network \
        --exclude=/etc/systemd/resolved.conf \
        --exclude=/var/lib/docker \
        --exclude=/var/lib/apt/lists \
        "$source_path" "$destination_path" 2>&1 | eval "$diff_filter" || true)

    if [ -n "$diff_output" ]; then
        echo -e "${RED}Unexpected differences detected:${NC}"
        echo "$diff_output"
        echo -e "\n${YELLOW}Validation failed but migration completed. Check above differences.${NC}"
    else
        echo -e "${GREEN}Verification successful!${NC}"
    fi

    # Cleanup
    umount "$mount_point" && rmdir "$mount_point"
}

# Enhanced Mount/Unmount functionality
mount_unmount_menu() {
    while true; do
        echo -e "\n${GREEN}Select operation:${NC}"
        PS3="Choose action (1-2): "
        select action in "Mount Application" "Unmount Application" "Return to Main Menu"; do
            case $REPLY in
                1|2|3) break ;;
                *) echo -e "${RED}Invalid choice!${NC}" ;;
            esac
        done

        case $action in
            "Mount Application")
                # Get unmounted datasets
                mapfile -t datasets < <(zfs list -H -o name | grep "^$ZFS_DATASET_BASE/")
                if [ ${#datasets[@]} -eq 0 ]; then
                    echo -e "${YELLOW}No applications found under $ZFS_DATASET_BASE!${NC}"
                    continue
                fi

                # Filter out mounted datasets
                mount_candidates=()
                for dataset in "${datasets[@]}"; do
                    app_name=$(basename "$dataset")
                    mount_point="$MOUNTED_BASE/$app_name"
                    if [ ! -d "$mount_point" ] || ! mountpoint -q "$mount_point"; then
                        mount_candidates+=("$app_name")
                    fi
                done

                if [ ${#mount_candidates[@]} -eq 0 ]; then
                    echo -e "${YELLOW}All applications are already mounted!${NC}"
                    continue
                fi

                # Dataset selection
                PS3="Select application to mount: "
                select app_name in "${mount_candidates[@]}"; do
                    [[ -n "$app_name" ]] && break
                    echo -e "${RED}Invalid selection!${NC}"
                done

                # Mount operation
                dataset="$ZFS_DATASET_BASE/$app_name"
                mount_point="$MOUNTED_BASE/$app_name"
                mkdir -p "$mount_point"
                if mount -t zfs "$dataset" "$mount_point"; then
                    echo -e "${GREEN}Successfully mounted $app_name${NC}"
                else
                    echo -e "${RED}Failed to mount $app_name!${NC}"
                    rmdir "$mount_point" 2>/dev/null
                fi
                ;;

            "Unmount Application")
                # Get mounted applications
                unmount_candidates=()
                for dir in "$MOUNTED_BASE"/*/; do
                    [[ -d "$dir" ]] || continue
                    dir=${dir%/}  # Remove trailing slash
                    if mountpoint -q "$dir"; then
                        unmount_candidates+=("$(basename "$dir")")
                    fi
                done

                if [ ${#unmount_candidates[@]} -eq 0 ]; then
                    echo -e "${YELLOW}No mounted applications found!${NC}"
                    continue
                fi

                # Application selection
                PS3="Select application to unmount: "
                select app_name in "${unmount_candidates[@]}"; do
                    [[ -n "$app_name" ]] && break
                    echo -e "${RED}Invalid selection!${NC}"
                done

                # Unmount operation
                mount_point="$MOUNTED_BASE/$app_name"
                if umount "$mount_point"; then
                    rmdir "$mount_point"
                    echo -e "${GREEN}Successfully unmounted $app_name${NC}"
                else
                    echo -e "${RED}Failed to unmount $app_name!${NC}"
                fi
                ;;

            "Return to Main Menu")
                return 0
                ;;
        esac
    done
}

# Main menu interface
main_menu() {
    while true; do
        echo -e "\n${GREEN}TrueNAS Jail Migration Manager${NC}"
        echo "1) Migrate Jail"
        echo "2) Configure Paths"
        echo "3) Manage Application Mounts"
        echo "4) Exit"
        read -p "Enter choice: " choice

        case $choice in
            1)
                read -p "Enter source jail name: " source_name
                if validate_environment "$source_name"; then
                    read -p "Use same name for destination? [y/N] " same_name
                    dest_name="$source_name"
                    [[ "$same_name" =~ ^[Yy]$ ]] || {
                        read -p "Enter destination jail name: " dest_name
                        while [[ -z "$dest_name" ]]; do
                            echo -e "${RED}Destination name required!${NC}"
                            read -p "Enter destination jail name: " dest_name
                        done
                    }

                    read -p "Migrate ${source_name} to ${dest_name}? [y/N] " confirm
                    [[ "$confirm" =~ ^[Yy]$ ]] && {
                        echo -e "${YELLOW}Stopping source jail...${NC}"
                        jlmkr stop "$source_name" 2>/dev/null || true
                        
                        perform_safe_migration "$source_name" "$dest_name" && \
                            echo -e "${GREEN}Migration completed!${NC}" || \
                            echo -e "${RED}Migration encountered issues!${NC}"
                    }
                fi
                ;;
            2)
                init_config
                echo -e "${GREEN}Configuration updated!${NC}"
                ;;
            3)
                mount_unmount_menu
                ;;
            4)
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid selection!${NC}"
                ;;
        esac
    done
}

# Safety traps and execution
trap 'echo -e "${RED}Aborted!${NC}"; exit 1' SIGINT
load_config
main_menu

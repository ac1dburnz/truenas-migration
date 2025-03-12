#!/bin/bash

# Universal systemd-nspawn migration script
CONFIG_FILE="$HOME/.migration_config"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

init_config() {
    echo -e "${YELLOW}Initial configuration:${NC}"
    read -p "Jailmaker base directory (default: /mnt/jailmaker): " JAILMAKER_BASE
    JAILMAKER_BASE=${JAILMAKER_BASE:-/mnt/jailmaker}
    
    read -p "Mount point base (default: /mnt/truenas): " MOUNTED_BASE
    MOUNTED_BASE=${MOUNTED_BASE:-/mnt/truenas}
    
    read -p "ZFS dataset base (e.g., pool/.ix-virt/containers): " ZFS_DATASET_BASE
    [ -z "$ZFS_DATASET_BASE" ] && { echo -e "${RED}ZFS path required!${NC}"; exit 1; }

    cat > "$CONFIG_FILE" <<EOL
JAILMAKER_BASE='$JAILMAKER_BASE'
MOUNTED_BASE='$MOUNTED_BASE'
ZFS_DATASET_BASE='$ZFS_DATASET_BASE'
EOL
}

load_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" || { init_config; source "$CONFIG_FILE"; }
}

universal_network_setup() {
    local dest_path=$1
    mkdir -p "$dest_path/etc/systemd/network"
    
    echo -e "${YELLOW}Network Configuration:${NC}"
    read -p "IP address (CIDR): " ip
    read -p "Gateway: " gw

    cat > "$dest_path/etc/systemd/network/eth0.network" <<EOF
[Match]
Name=eth0

[Network]
Address=$ip
Gateway=$gw
EOF

    # Universal DNS handling
    if [ -L "$dest_path/etc/resolv.conf" ]; then
        rm -f "$dest_path/etc/resolv.conf"
    fi
    echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" > "$dest_path/etc/resolv.conf"
}

safe_sync() {
    local src=$1 dst=$2
    rsync -aHAX --delete --exclude={"/etc/systemd/network/*.network","/var/lib/apt/lists/*","/var/cache/dnf","/var/cache/yum","/var/lib/dpkg","/var/lib/rpm","/var/lib/PackageKit","/snap","/.snapshots"} "$src" "$dst"
}

verify_migration() {
    local src=$1 dst=$2
    diff -rq --exclude={"*.network","*.cache","*.lock","*.swp","*.tmp"} "$src" "$dst" 2>&1 | grep -vE 'recursive directory loop|No such file or directory'
}

migrate_instance() {
    local src_name=$1 dest_name=$2
    local src_path="$JAILMAKER_BASE/$src_name/rootfs"
    local mount_point="$MOUNTED_BASE/$dest_name"
    local dest_path="$mount_point/rootfs"
    local zfs_dataset="$ZFS_DATASET_BASE/$dest_name"

    [ ! -d "$src_path" ] && { echo -e "${RED}Source missing!${NC}"; return 1; }
    zfs list "$zfs_dataset" &>/dev/null || { echo -e "${RED}ZFS dataset missing!${NC}"; return 1; }

    mkdir -p "$mount_point"
    mount -t zfs "$zfs_dataset" "$mount_point" || return 1
    
    echo -e "${YELLOW}Starting migration...${NC}"
    safe_sync "$src_path/" "$dest_path"
    
    universal_network_setup "$dest_path"
    
    echo -e "${YELLOW}Verifying...${NC}"
    local diff_output=$(verify_migration "$src_path" "$dest_path")
    [ -n "$diff_output" ] && echo -e "${RED}Differences:\n$diff_output${NC}" || echo -e "${GREEN}Verified OK${NC}"

    umount "$mount_point" && rmdir "$mount_point"
}

main_menu() {
    while true; do
        echo -e "\n${GREEN}Universal Container Migrator${NC}"
        echo "1) Migrate Container"
        echo "2) Configure Paths"
        echo "3) Exit"
        read -p "Choice: " choice

        case $choice in
            1)
                read -p "Source name: " src
                read -p "Destination name: " dest
                [ -z "$dest" ] && dest=$src
                migrate_instance "$src" "$dest" && echo -e "${GREEN}Done!${NC}" || echo -e "${RED}Failed!${NC}"
                ;;
            2)
                init_config
                ;;
            3)
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid!${NC}"
                ;;
        esac
    done
}

trap 'echo -e "${RED}Aborted!${NC}"; exit 1' SIGINT
load_config
main_menu

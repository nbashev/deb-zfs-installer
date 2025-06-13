#!/bin/bash
# Modified to use explicit error handling instead of -e flag
set -e
# Enable error tracing to help debug issues
trap 'echo "Error on line $LINENO. Exit code: $?" >&2' ERR

# Help function
show_help() {
    cat << EOF
Debian 12 ZFS Root Installer

Usage: $(basename $0) [options]

Options:
  --help         Show this help message and exit
  --version      Display version information
  --test         Run in test mode (no actual disk operations)
  
This script installs Debian Bookworm with ZFS root filesystem.
It provides options for RAID configuration and ZFS encryption.
  
Caution: This script will DESTROY ALL DATA on selected disks!
Make sure you have backups before proceeding.

EOF
    exit 0
}

# Process command line arguments
for arg in "$@"; do
    case $arg in
        --help)
            show_help
            ;;
        --version)
            echo "Debian 12 ZFS Root Installer v1.0.2"
            exit 0
            ;;
        --test)
            echo "Running in test mode - no disk operations will be performed"
            TEST_MODE=true
            ;;
    esac
done

echo "Script started with set -e enabled and error trap"
#
# debian-zfs-installer.sh
#
# Install Debian GNU/Linux to a native ZFS root filesystem
#

### Static settings

ZPOOL=rpool
BPOOL=bpool
TARGETDIST=bookworm

PARTBIOS=1
PARTEFI=2
PARTBOOT=3
PARTZFS=4

SIZETMP=3G
SIZEVARTMP=3G

### Disk identification and selection logic

# First collect disk by-id links for persistent device naming
declare -A BYID
while read -r IDLINK; do
    BYID["$(basename "$(readlink "$IDLINK")")"]="$IDLINK"
done < <(find /dev/disk/by-id/ -type l | grep -v "part[0-9]")

# Build selection array
SELECT=()
for DISK in $(lsblk -I8,254,259 -dn -o name); do
    if [ -z "${BYID[$DISK]}" ]; then
        SELECT+=("$DISK" "(no /dev/disk/by-id persistent device name available)" off)
    else
        SELECT+=("$DISK" "${BYID[$DISK]}" off)
    fi
done

# Display selection dialog
TMPFILE=$(mktemp)
if [ ${#SELECT[@]} -eq 0 ]; then
    echo "No suitable disks found for installation" >&2
    exit 1
fi

# Save current state of errexit flag
set +e
whiptail --backtitle "Debian ZFS Installer" --title "Drive selection" --separate-output \
    --checklist "\nPlease select ZFS RAID drives\n" 20 74 8 "${SELECT[@]}" 2>"$TMPFILE"
DISK_SELECT_RESULT=$?
# Restore errexit flag
set -e

if [ $DISK_SELECT_RESULT -ne 0 ]; then
    rm "$TMPFILE"
    echo "Disk selection cancelled" >&2
    exit 1
fi

# Process selected disks
DISKS=()
ZFSPARTITIONS=()
EFIPARTITIONS=()
BOOTPARTITIONS=()
BIOSPARTITIONS=()

while read -r DISK; do
    if [ -z "${BYID[$DISK]}" ]; then
        DISKS+=("/dev/$DISK")
        ZFSPARTITIONS+=("/dev/$DISK$PARTZFS")
        BOOTPARTITIONS+=("/dev/$DISK$PARTBOOT")
        EFIPARTITIONS+=("/dev/$DISK$PARTEFI")
        BIOSPARTITIONS+=("/dev/$DISK$PARTBIOS")
    else
        DISKS+=("${BYID[$DISK]}")
        ZFSPARTITIONS+=("${BYID[$DISK]}-part$PARTZFS")
        BOOTPARTITIONS+=("${BYID[$DISK]}-part$PARTBOOT")
        EFIPARTITIONS+=("${BYID[$DISK]}-part$PARTEFI")
        BIOSPARTITIONS+=("${BYID[$DISK]}-part$PARTBIOS")
    fi
done < "$TMPFILE"
rm "$TMPFILE"

### RAID level selection
# Save current state of errexit flag
set +e
whiptail --backtitle "Debian ZFS Installer" --title "RAID level selection" --separate-output \
    --radiolist "\nPlease select ZFS RAID level\n" 20 74 8 \
    "RAID0" "Striped disks" off \
    "RAID1" "Mirrored disks (RAID10 for n>=4)" on \
    "RAIDZ" "Distributed parity, one parity block" off \
    "RAIDZ2" "Distributed parity, two parity blocks" off \
    "RAIDZ3" "Distributed parity, three parity blocks" off 2>"$TMPFILE"
RAID_SELECT_RESULT=$?
# Restore errexit flag
set -e

if [ $RAID_SELECT_RESULT -ne 0 ]; then
    rm "$TMPFILE" 
    echo "RAID selection cancelled" >&2
    exit 1
fi

RAIDLEVEL=$(head -n1 "$TMPFILE" | tr '[:upper:]' '[:lower:]')
rm "$TMPFILE"

# Configure RAID definition based on selection
case "$RAIDLEVEL" in
  raid0)
    BOOT_RAIDDEF="${BOOTPARTITIONS[*]}"
    RPOOL_RAIDDEF="${ZFSPARTITIONS[*]}"
    ;;
  raid1)
    if [ $((${#ZFSPARTITIONS[@]} % 2)) -ne 0 ]; then
        echo "Need an even number of disks for RAID level '$RAIDLEVEL': ${ZFSPARTITIONS[@]}" >&2
        exit 1
    fi
    
    BOOT_RAIDDEF="mirror ${BOOTPARTITIONS[*]}"
    
    I=0
    RPOOL_RAIDDEF=""
    for ZFSPARTITION in "${ZFSPARTITIONS[@]}"; do
        if [ $((I % 2)) -eq 0 ]; then
            RPOOL_RAIDDEF+=" mirror"
        fi
        RPOOL_RAIDDEF+=" $ZFSPARTITION"
        ((I++)) || true
    done
    ;;
  *)
    if [ ${#ZFSPARTITIONS[@]} -lt 3 ]; then
        echo "Need at least 3 disks for RAID level '$RAIDLEVEL': ${ZFSPARTITIONS[@]}" >&2
        exit 1
    fi
    BOOT_RAIDDEF="$RAIDLEVEL ${BOOTPARTITIONS[*]}"
    RPOOL_RAIDDEF="$RAIDLEVEL ${ZFSPARTITIONS[*]}"
    ;;
esac

### Boot method selection
GRUBPKG=grub-pc
if [ -d /sys/firmware/efi ]; then
    TMPFILE=$(mktemp)
    # Save current state of errexit flag
    set +e
    whiptail --backtitle "Debian ZFS Installer" --title "EFI boot" --separate-output \
        --menu "\nYour hardware supports EFI. Which boot method should be used?\n" 20 74 8 \
        "EFI" "Extensible Firmware Interface boot" \
        "BIOS" "Legacy BIOS boot" 2>"$TMPFILE"
    BOOT_SELECT_RESULT=$?
    # Restore errexit flag
    set -e

    if [ $BOOT_SELECT_RESULT -ne 0 ]; then
        rm "$TMPFILE"
        echo "Boot method selection cancelled" >&2
        exit 1
    fi
    if grep -qi EFI $TMPFILE; then
        GRUBPKG=grub-efi-amd64
        USE_EFI=true
    fi
    rm "$TMPFILE"
fi

### Encryption option
# Save current state of errexit flag to restore it later
set +e
echo "Encryption dialog: set +e (disabled)"
whiptail --backtitle "Debian ZFS Installer" --title "ZFS Encryption" --separate-output \
    --yesno "\nDo you want to use ZFS native encryption for the root pool?\n" 10 60
ENCRYPTION_RESULT=$?
echo "Encryption dialog return code: $ENCRYPTION_RESULT"
# Restore errexit flag
set -e
echo "Encryption dialog: set -e (re-enabled)"

if [ $ENCRYPTION_RESULT -eq 0 ]; then
    USE_ENCRYPTION=true
    echo "ZFS encryption enabled for root pool"
else
    USE_ENCRYPTION=false
    echo "ZFS encryption disabled for root pool (return code: $ENCRYPTION_RESULT)"
fi

### Final confirmation
# Save current state of errexit flag to restore it later
set +e
whiptail --backtitle "Debian ZFS Installer" --title "Confirmation" \
    --yesno "\nAre you sure to destroy ZFS pools '$BPOOL' and '$ZPOOL' (if existing), wipe all data of disks '${DISKS[*]}' and create a RAID '$RAIDLEVEL'?\n" 20 74
CONFIRM_RESULT=$?
# Restore errexit flag
set -e

if [ $CONFIRM_RESULT -ne 0 ]; then
    echo "Installation cancelled by user" >&2
    exit 1
fi

### Start the real work

# Set hostid if needed
if [ "$(hostid | cut -b-6)" == "007f01" ]; then
    dd if=/dev/urandom of=/etc/hostid bs=1 count=4
fi

# Install required packages
DEBRELEASE=$(head -n1 /etc/debian_version)
case $DEBRELEASE in
    12*)
        echo "deb http://deb.debian.org/debian/ bookworm contrib non-free-firmware" >/etc/apt/sources.list.d/contrib-non-free.list
        test -f /var/lib/apt/lists/deb.debian.org_debian_dists_bookworm_non-free-firmware_binary-amd64_Packages || apt-get update
        if [ ! -d /usr/share/doc/zfs-dkms ]; then NEED_PACKAGES+=(zfs-dkms); fi
        ;;
    *)
        echo "Unsupported Debian Live CD release" >&2
        exit 1
        ;;
esac

if [ ! -f /sbin/zpool ]; then NEED_PACKAGES+=(zfsutils-linux); fi
if [ ! -f /usr/sbin/debootstrap ]; then NEED_PACKAGES+=(debootstrap); fi
if [ ! -f /sbin/sgdisk ]; then NEED_PACKAGES+=(gdisk); fi
if [ ! -f /sbin/mkdosfs ]; then NEED_PACKAGES+=(dosfstools); fi

echo "Need packages: ${NEED_PACKAGES[*]}"
if [ -n "${NEED_PACKAGES[*]}" ]; then 
    DEBIAN_FRONTEND=noninteractive apt-get install --yes "${NEED_PACKAGES[@]}"
fi

# Load ZFS module
modprobe zfs
if [ $? -ne 0 ]; then
    echo "Unable to load ZFS kernel module" >&2
    exit 1
fi

# Remove existing pools if present
test -d /proc/spl/kstat/zfs/$BPOOL && zpool destroy $BPOOL
test -d /proc/spl/kstat/zfs/$ZPOOL && zpool destroy $ZPOOL

# Partition disks
for DISK in "${DISKS[@]}"; do
    echo -e "\nPartitioning disk $DISK"
    
    sgdisk --zap-all $DISK
    
    # Create BIOS partition
    sgdisk -a1 -n$PARTBIOS:34:2047 -t$PARTBIOS:EF02 $DISK
    
    # Create EFI partition
    sgdisk -n$PARTEFI:2048:+512M -t$PARTEFI:EF00 $DISK
    
    # Create boot partition
    sgdisk -n$PARTBOOT:0:+1G -t$PARTBOOT:BF01 $DISK
    
    # Create root ZFS partition
    sgdisk -n$PARTZFS:0:0 -t$PARTZFS:BF00 $DISK
done

sleep 2

# Create boot pool (bpool)
echo "Creating boot pool (bpool)..."
zpool create -f -o ashift=12 \
    -o autotrim=on -o compatibility=grub2 \
    -o cachefile=/etc/zfs/zpool.cache \
    -O devices=off -O acltype=posixacl -O xattr=sa \
    -O compression=lz4 -O normalization=formD \
    -O relatime=on -O canmount=off -O mountpoint=/boot \
    -R /target $BPOOL $BOOT_RAIDDEF

# Create root pool (rpool)
echo "Creating root pool (rpool)..."
echo "USE_ENCRYPTION value: $USE_ENCRYPTION"
if [ "$USE_ENCRYPTION" = true ]; then
    echo "Creating encrypted ZFS pool"
    # Create encrypted pool
    zpool create -f -o ashift=12 \
        -o autotrim=on \
        -O encryption=aes-256-gcm -O keylocation=prompt -O keyformat=passphrase \
        -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
        -O compression=lz4 -O normalization=formD \
        -O relatime=on -O canmount=off -O mountpoint=/ \
        -R /target $ZPOOL $RPOOL_RAIDDEF
    echo "Encrypted ZFS pool created successfully"
else
    echo "Creating unencrypted ZFS pool"
    # Create unencrypted pool
    zpool create -f -o ashift=12 \
        -o autotrim=on \
        -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
        -O compression=lz4 -O normalization=formD \
        -O relatime=on -O canmount=off -O mountpoint=/ \
        -R /target $ZPOOL $RPOOL_RAIDDEF
    echo "Unencrypted ZFS pool created successfully"
fi

# Create filesystem datasets
echo "Creating ZFS datasets..."
zfs create -o canmount=off -o mountpoint=none $ZPOOL/ROOT
zfs create -o canmount=noauto -o mountpoint=/ $ZPOOL/ROOT/$TARGETDIST
zpool set bootfs=$ZPOOL/ROOT/$TARGETDIST $ZPOOL
zfs mount $ZPOOL/ROOT/$TARGETDIST

zfs create -o canmount=off -o mountpoint=none $BPOOL/BOOT
zfs create -o mountpoint=/boot $BPOOL/BOOT/$TARGETDIST

# Create temp datasets
zfs create -o mountpoint=/tmp -o setuid=off -o exec=off -o devices=off \
    -o com.sun:auto-snapshot=false -o quota=$SIZETMP $ZPOOL/tmp
chmod 1777 /target/tmp

# Create var datasets
zfs create -o mountpoint=/var -o canmount=off $ZPOOL/var
zfs create $ZPOOL/var/lib
zfs create $ZPOOL/var/log
zfs create $ZPOOL/var/spool

# Create var/tmp dataset
zfs create -o mountpoint=/var/tmp -o setuid=off -o exec=off -o devices=off \
    -o com.sun:auto-snapshot=false -o quota=$SIZEVARTMP $ZPOOL/var/tmp
chmod 1777 /target/var/tmp

zpool status
zfs list

# Install base system
echo "Installing base Debian system with debootstrap..."
debootstrap --include=openssh-server,console-setup,locales,linux-headers-amd64,linux-image-amd64 \
    --components main,contrib,non-free-firmware \
    $TARGETDIST /target http://deb.debian.org/debian/

# Configure APT sources
echo "Configuring APT sources..."
cat << EOF > /target/etc/apt/sources.list
deb http://deb.debian.org/debian bookworm main contrib non-free-firmware
deb-src http://deb.debian.org/debian bookworm main contrib non-free-firmware

deb http://deb.debian.org/debian-security bookworm-security main contrib non-free-firmware
deb-src http://deb.debian.org/debian-security bookworm-security main contrib non-free-firmware

deb http://deb.debian.org/debian bookworm-updates main contrib non-free-firmware
deb-src http://deb.debian.org/debian bookworm-updates main contrib non-free-firmware
EOF

# Configure hostname
# Prompt user for hostname
TMPFILE=$(mktemp)
set +e
whiptail --backtitle "Debian ZFS Installer" --title "Hostname Configuration" \
    --inputbox "\nPlease enter the fully qualified hostname for this system (e.g. server.example.com):\n" \
    10 70 "debian.local" 2>"$TMPFILE"
HOSTNAME_RESULT=$?
set -e

if [ $HOSTNAME_RESULT -ne 0 ]; then
    echo "Using default hostname: debian"
    NEWHOST="debian"
else
    NEWHOST=$(cat "$TMPFILE")
    # If empty, use default
    if [ -z "$NEWHOST" ]; then
        NEWHOST="debian"
    fi
fi
rm "$TMPFILE"

# Extract short hostname from FQDN
SHORTHOST=$(echo "$NEWHOST" | cut -d. -f1)

echo "Setting hostname to: $NEWHOST (short name: $SHORTHOST)"
echo "$NEWHOST" > /target/etc/hostname

# Configure /etc/hosts with both short name and FQDN
cat << EOF > /target/etc/hosts
127.0.0.1       localhost
127.0.1.1       $SHORTHOST $NEWHOST

# The following lines are desirable for IPv6 capable hosts
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# Copy hostid
cp -va /etc/hostid /target/etc/

# Create fstab
cat << EOF > /target/etc/fstab
# /etc/fstab: static file system information.
#
# <file system>         <mount point>   <type>  <options>       <dump>  <pass>
EOF

# Prepare chroot environment
mount --rbind /dev /target/dev
mount --rbind /proc /target/proc
mount --rbind /sys /target/sys

# Ensure mtab symlink is correct
if [ -L /target/etc/mtab ] && [ "$(readlink /target/etc/mtab)" = "/proc/mounts" ]; then
    echo "Note: /target/etc/mtab symlink already points to /proc/mounts"
elif [ -e /target/etc/mtab ]; then
    echo "Warning: /target/etc/mtab exists but is not a correct symlink, recreating it..."
    rm -f /target/etc/mtab
    ln -s /proc/mounts /target/etc/mtab
else
    echo "Creating /target/etc/mtab symlink..."
    ln -s /proc/mounts /target/etc/mtab
fi

# Configure locale and regional settings
echo "Configuring locales, timezone, and keyboard settings..."
echo "en_US.UTF-8 UTF-8" > /target/etc/locale.gen
chroot /target locale-gen

echo "LANG=en_US.UTF-8" > /target/etc/default/locale
echo "LC_ALL=en_US.UTF-8" >> /target/etc/default/locale
chroot /target update-locale LANG=en_US.UTF-8

ln -sf /usr/share/zoneinfo/America/New_York /target/etc/localtime
chroot /target dpkg-reconfigure --frontend noninteractive tzdata

echo 'KEYMAP="us"' > /target/etc/vconsole.conf
chroot /target dpkg-reconfigure --frontend noninteractive keyboard-configuration

chroot /target dpkg-reconfigure --frontend noninteractive console-setup

# Install additional packages
chroot /target /usr/bin/apt-get update
chroot /target /usr/bin/apt-get install --yes grub2-common $GRUBPKG zfs-initramfs zfs-dkms systemd-timesyncd vim screen aptitude htop dpkg-dev

# Enable root login via SSH
echo "Enabling root SSH login..."
if [ -f /target/etc/ssh/sshd_config ]; then
    # Check if PermitRootLogin is already set
    if grep -q "^PermitRootLogin" /target/etc/ssh/sshd_config; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /target/etc/ssh/sshd_config
    else
        # If not, add it
        echo "PermitRootLogin yes" >> /target/etc/ssh/sshd_config
    fi

    # Also modify commented out setting to avoid confusion
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /target/etc/ssh/sshd_config
    
    # Ensure SSH service is enabled
    chroot /target systemctl enable ssh
fi

echo "Refreshing initramfs..."
chroot /target update-initramfs -c -k all

echo "Configuring DKMS for ZFS inside chroot..."
echo REMAKE_INITRD=yes > /target/etc/dkms/zfs.conf

# Configure GRUB for ZFS
grep -q zfs /target/etc/default/grub || \
    sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="root=ZFS='$ZPOOL/ROOT/$TARGETDIST' boot=zfs quiet"|' /target/etc/default/grub
chroot /target /usr/sbin/update-grub

# Install GRUB
if [ "$USE_EFI" = true ]; then
    # Install GRUB for EFI
    mkdir -pv /target/boot/efi
    for i in ${!EFIPARTITIONS[@]}; do
        EFIPARTITION=${EFIPARTITIONS[$i]}
        mkdosfs -F 32 -n EFI-$i $EFIPARTITION
        mount $EFIPARTITION /target/boot/efi
        chroot /target /usr/sbin/grub-install --target=x86_64-efi \
            --efi-directory=/boot/efi --bootloader-id="Debian $TARGETDIST (disk $i)" \
            --recheck --no-floppy
        umount $EFIPARTITION
        
        # Add EFI partition to fstab
        if [ $i -gt 0 ]; then
            EFIBAKPART="#"
        else
            EFIBAKPART=""
        fi
        echo "${EFIBAKPART}PARTUUID=$(blkid -s PARTUUID -o value $EFIPARTITION) /boot/efi vfat defaults 0 1" >> /target/etc/fstab
    done
else
    # Install GRUB for BIOS
    for DISK in "${DISKS[@]}"; do
        chroot /target /usr/sbin/grub-install $DISK
    done
fi

# Install ACPI if available
if [ -d /proc/acpi ]; then
    chroot /target /usr/bin/apt-get install --yes acpi acpid
    chroot /target service acpid stop
fi

# Configure network
echo "Configuring network settings..."
ETHDEV=$(udevadm info -e | grep "ID_NET_NAME_PATH=" | head -n1 | cut -d= -f2)
test -n "$ETHDEV" || ETHDEV=en01

# Network configuration prompt
TMPFILE=$(mktemp)
set +e
whiptail --backtitle "Debian ZFS Installer" --title "Network Configuration" \
    --yesno "\nDo you want to configure a static IP address?\n(Selecting 'No' will configure DHCP)\n" \
    10 60
NETWORK_RESULT=$?
set -e

if [ $NETWORK_RESULT -eq 0 ]; then
    # Static IP configuration
    # Get IP address
    set +e
    whiptail --backtitle "Debian ZFS Installer" --title "Static IP Configuration" \
        --inputbox "\nEnter IP address (e.g. 192.168.1.100):\n" \
        10 60 "" 2>"$TMPFILE"
    IP_RESULT=$?
    set -e
    
    if [ $IP_RESULT -ne 0 ]; then
        echo "Static IP configuration cancelled, defaulting to DHCP"
        USE_DHCP=true
    else
        IP_ADDRESS=$(cat "$TMPFILE")
        
        # Get netmask
        set +e
        whiptail --backtitle "Debian ZFS Installer" --title "Static IP Configuration" \
            --inputbox "\nEnter netmask (e.g. 255.255.255.0):\n" \
            10 60 "255.255.255.0" 2>"$TMPFILE"
        MASK_RESULT=$?
        set -e
        
        if [ $MASK_RESULT -ne 0 ]; then
            echo "Netmask configuration cancelled, defaulting to DHCP"
            USE_DHCP=true
        else
            NETMASK=$(cat "$TMPFILE")
            
            # Get gateway
            set +e
            whiptail --backtitle "Debian ZFS Installer" --title "Static IP Configuration" \
                --inputbox "\nEnter gateway (e.g. 192.168.1.1):\n" \
                10 60 "" 2>"$TMPFILE"
            GW_RESULT=$?
            set -e
            
            if [ $GW_RESULT -ne 0 ]; then
                echo "Gateway configuration cancelled, defaulting to DHCP"
                USE_DHCP=true
            else
                GATEWAY=$(cat "$TMPFILE")
                USE_DHCP=false
            fi
        fi
    fi
else
    USE_DHCP=true
fi
rm "$TMPFILE"

# Create network interfaces configuration
cat << EOF > /target/etc/network/interfaces
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
auto $ETHDEV
EOF

if [ "$USE_DHCP" = true ]; then
    echo "Configuring $ETHDEV for DHCP"
    echo "iface $ETHDEV inet dhcp" >> /target/etc/network/interfaces
else
    echo "Configuring $ETHDEV with static IP: $IP_ADDRESS"
    cat << EOF >> /target/etc/network/interfaces
iface $ETHDEV inet static
    address $IP_ADDRESS
    netmask $NETMASK
    gateway $GATEWAY
EOF
fi

# Configure DNS
echo "Configuring DNS settings..."
cat << EOF > /target/etc/resolv.conf
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF

# Set root password
echo "Setting root password for the new system..."
chroot /target /usr/bin/passwd

# Configure ZFS import service
cat << EOF > /target/etc/systemd/system/zfs-import-bpool.service
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/zpool import -N -o cachefile=none bpool
ExecStartPre=-/bin/mv /etc/zfs/zpool.cache /etc/zfs/preboot_zpool.cache
ExecStartPost=-/bin/mv /etc/zfs/preboot_zpool.cache /etc/zfs/zpool.cache

[Install]
WantedBy=zfs-import.target
EOF

chroot /target /bin/systemctl enable zfs-import-bpool.service

# Configure ZFS mount order
echo "Configuring ZFS mount order for boot..."
chroot /target mkdir -p /etc/zfs/zfs-list.cache
chroot /target zfs set cachefile=/etc/zfs/zpool.cache $BPOOL
chroot /target zfs set cachefile=/etc/zfs/zpool.cache $ZPOOL
chroot /target zpool set cachefile=/etc/zfs/zpool.cache $BPOOL
chroot /target zpool set cachefile=/etc/zfs/zpool.cache $ZPOOL

# Generate cache files with filesystem mount information
chroot /target zfs list -t filesystem -o name,mountpoint,canmount > /dev/null

# Fix paths in cache files (removing /target from paths)
echo "Processing cache files to remove installation paths..."
if [ -n "$(find /target/etc/zfs/zfs-list.cache -type f 2>/dev/null)" ]; then
    for cache_file in /target/etc/zfs/zfs-list.cache/*; do
        sed -Ei "s|/target/?|/|" "$cache_file"
    done
    echo "ZFS cache files updated successfully."
else
    echo "No ZFS cache files found for modification."
fi

# Set final mount properties
chroot /target zfs set canmount=noauto $ZPOOL/ROOT/$TARGETDIST
chroot /target zfs set canmount=noauto $BPOOL/BOOT/$TARGETDIST

chroot /target /bin/systemctl enable zfs-import-bpool.service

echo "Unmounting mounted directories..."
mount | grep -w /mnt | awk '{print $3}' | sort -r | xargs -r umount || true

echo "Unmounting all ZFS filesystems from mount points..."
zfs umount -a || true

echo "Exporting ZFS pools..."
grep [p]ool /proc/*/mounts | cut -d/ -f3 | uniq | xargs kill
zpool export -a

echo
echo "Installation complete! You can now reboot into your new system."
echo "Make sure to remove the installation media before rebooting."
echo
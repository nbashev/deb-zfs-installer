# Debian ZFS Root Installer

This guide walks you through installing Debian with ZFS as the root filesystem using our installer script. The script automates the complex process of setting up a Debian system with native ZFS support.

## Recent Updates

### Version 1.0.2 (June 13, 2025)

- Added interactive hostname configuration with FQDN support
- Added option for static IP configuration
- Improved hosts file configuration with both short name and FQDN

### Version 1.0.1 (June 13, 2025)

- Fixed issue where script would exit when selecting "No" for encryption option
- Improved error handling throughout the script with better error messages
- Added proper help and version options (use `--help` for usage information)
- Enhanced debug output for troubleshooting
- Fixed mtab symlink handling during installation

## Prerequisites

1. **Debian Live Standard ISO**:
   Download and boot from [Debian Live 12.11.0 amd64 Standard ISO](https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-12.11.0-amd64-standard.iso)

2. **Internet Connection**:
   Ensure your system has internet access for package downloads

3. **Administrative Access**:
   Boot into the live environment and open a terminal with root privileges:

   ```bash
   sudo -i
   ```

## Installation

1. **Download the installer script**:

   ```bash
   wget https://raw.githubusercontent.com/DizkoDan/deb-zfs-installer/main/deb-12-zfs-install.sh
   ```

2. **Make the script executable**:

   ```bash
   chmod +x deb-12-zfs-install.sh
   ```

3. **Run the installer**:

   ```bash
   ./deb-12-zfs-install.sh
   ```

4. **Follow the prompts** to complete the installation

## What the Script Does

The installer automates the following processes:

### 1. System Preparation

- Identifies available disks using persistent device names (`/dev/disk/by-id`)
- Validates system requirements
- Installs necessary ZFS packages and tools

### 2. User Configuration

- **Disk Selection**: Choose the disk(s) for your ZFS installation
- **RAID Configuration**: Select from various RAID levels (RAID0, RAID1/mirror, RAIDZ, RAIDZ2, RAIDZ3)
- **Boot Method**: Choose between UEFI and Legacy BIOS boot methods
- **Encryption**: Option to enable native ZFS encryption for the root pool

### 3. Disk Preparation

- Partitions each selected disk:
  - BIOS boot partition (for legacy boot)
  - EFI partition (for UEFI boot)
  - Boot partition (for ZFS boot pool)
  - Root partition (for ZFS root pool)

### 4. ZFS Pool Creation

- Creates a boot pool (`bpool`) with GRUB compatibility
- Creates a root pool (`rpool`) with optional encryption
- Configures optimal ZFS properties for system use
- Creates dataset structure (ROOT, var, tmp, etc)

### 5. Base System Installation

- Installs Debian Bookworm using debootstrap
- Configures APT repositories with appropriate components
- Interactive hostname configuration (FQDN and short name)
- Network configuration with options for DHCP or static IP

### 6. System Configuration

- Configures locale settings (en_US.UTF-8)
- Sets timezone (America/New_York)
- Configures keyboard layout
- Enables SSH root login for remote administration
- Installs essential system packages
- Sets up system services
- Configures the bootloader (GRUB)

### 7. ZFS Configuration

- Creates the proper ZFS dataset hierarchy
- Sets appropriate ZFS mount properties
- Creates the ZFS import service for boot pool
- Configures ZFS cache files for proper imports

### 8. Finalization

- Generates the initial ramdisk with ZFS support
- Installs bootloader (GRUB) for selected boot method
- Sets root password
- Cleans up temporary files
- Exports ZFS pools properly
- Prepares the system for first boot

## After Installation

1. Reboot your system:

   ```bash
   reboot
   ```

2. Remove the installation media during reboot

3. Your system should boot into the new Debian installation with ZFS root

## Additional Features

- **Dataset Organization**: Optimized dataset layout following best practices
- **Temporary Directories**: Special datasets for `/tmp` and `/var/tmp` with security options
- **Variable Files**: Separate datasets for `/var` subdirectories
- **Performance**: Tuned compression and other ZFS properties for best performance
- **Boot Support**: Proper GRUB integration for ZFS boot

## Troubleshooting

If your system fails to boot:

1. Boot back into the Debian Live CD
2. Import your ZFS pools manually:

   ```bash
   zpool import -R /mnt rpool
   zpool import -R /mnt bpool
   ```

3. Check logs in `/mnt/var/log` for boot errors
4. Ensure GRUB was properly installed to all disks

## Contributing

Feel free to submit issues or pull requests to our repository to help improve this installer.

## License

This script is provided under the GPL v3 license.

## Credits

There's some good info out there. I gleaned some from all of these, and past experience setting up ZFS on buster manually. The scripts helped immensely as a starting point to work from.

- [OpenZFS Getting Started Guide](https://github.com/openzfs/openzfs-docs/blob/master/docs/Getting%20Started/Debian/Debian%20Bookworm%20Root%20on%20ZFS.rst)
- [Hajo Noerenberg's debian-buster-zfs-root script](https://github.com/hn/debian-buster-zfs-root)
- [danfossi's Debian-ZFS-Root-Installation-Script](https://github.com/danfossi/Debian-ZFS-Root-Installation-Script)
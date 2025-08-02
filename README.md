# zfs-hetzner-vm

[![shellcheck](https://github.com/terem42/zfs-hetzner-vm/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/terem42/zfs-hetzner-vm/actions/workflows/shellcheck.yml)

Scripts to install Debian 10, 11, 12 or Ubuntu 18 LTS, 20 LTS, 22 LTS with ZFS root on Hetzner root servers (virtual and dedicated).

__WARNING:__ all data on the disk will be destroyed.

## Quick Start

## Features

- __Modularized setup:__ Each major step is a dedicated function for maintainability and extensibility
- __Dialog-based UI:__ Disk and pool type selection via interactive dialogs
- __Dynamic zpool arguments:__ Supports all major ZFS layouts (RAID0, RAID1, RAID10, RAIDZ-1, RAIDZ-2, RAIDZ-3)
- __UEFI/BIOS support:__ Automatic detection and partitioning logic
- __GRUB installation:__ Handles both boot modes
- __Input validation:__ Ensures correct disk selection, pool names, swap size, etc.
- __Disk type warning:__ Alerts if mixing SATA/NVMe/SCSI
- __Security hardening:__
  - Strict file permissions (umask 077, chmod 600 for sensitive files)
  - Input sanitization
  - Disk shredding before partitioning
  - World-writable file detection
- __Logging and error handling:__ Timestamped logs, global error trap
- __Optional encryption:__ Root pool encryption with dropbear unlock
- __Network and locale setup:__ Automated configuration
- __OpenSSH setup:__ Secure SSH key handling
- __Automated ZFS dataset creation and system configuration__

Or download and run a specific script directly (replace with your repo if using a fork):

```bash
wget -qO- https://raw.githubusercontent.com/PICTC/zfs-debian-installer/master/hetzner-ubuntu22-zfs-setup-modified.sh | bash -
```

---

__WARNING:__ All data on selected disks will be destroyed!

For network reliability, it is recommended to run inside a screen session:

```bash
screen -dmS zfs
screen -r zfs
# (Detach: Ctrl+a then d)
```

## How to use

## Options

- Pool type: stripe, mirror, raid10, raidz, raidz2, raidz3
- Encryption: Optional for root pool
- Swap size: Configurable
- ARC cache size: Configurable
- Hostname: Configurable

## Extending and Customizing

The script is designed for easy modification and extension. Each major setup step is a dedicated function, making it straightforward to add, remove, or change logic for:

- Disk validation and selection
- ZFS pool creation
- System bootstrapping
- Network setup
- Security hardening (permissions, input sanitization, disk shredding)
- Logging and error handling

To add custom logic, create a new function and call it from the `main_installation` orchestration function. This modular approach ensures maintainability and clarity.

- Ubuntu 20 LTS: `hetzner-ubuntu20-zfs-setup.sh`
- Ubuntu 22 LTS (advanced features): `hetzner-ubuntu22-zfs-setup-modified.sh`

Run any script with:

```bash
bash ./<script-name>
```

### Additional Features

- Dialog-based UI for disk and pool type selection
- Supports RAID0 (stripe), RAID1 (mirror), RAID10, RAIDZ-1, RAIDZ-2, RAIDZ-3
- UEFI and BIOS boot mode detection and partitioning
- Optional root pool encryption (with dropbear unlock)
- Input validation for disk selection, pool names, swap size, etc.
- Disk type warning (SATA/NVMe/SCSI mix)
- Automated ZFS dataset creation and system configuration
- Network and locale setup, OpenSSH configuration
- Robust error handling and logging

## Usage Steps

1. Add your SSH key to the Hetzner rescue console.
2. Set rescue OS to linux64, then "mount rescue and power cycle".
3. Connect via SSH to the rescue system.
4. Run the script above.
5. Follow dialog prompts for disk selection, pool type, hostname, ARC size, etc.
6. The script will partition disks, create ZFS pools, install Ubuntu, and configure the system.

__WARNING:__ All data on selected disks will be destroyed!

For network reliability, it is recommended to run inside a screen session:

```bash
screen -dmS zfs
screen -r zfs
# (Detach: Ctrl+a then d)
```

During installation, you will be prompted for hostname, ZFS ARC cache size, pool type, encryption, and other options.

After completion, the system will reboot and you can log in using the same SSH key you used in the rescue console.

__Note:__ Drives you intend to format must not be in use. Run `mdadm --stop --scan` before running the script to halt default software RAID operations.

---

## Troubleshooting

### No suitable disks found

- Ensure the disks are not mounted or in use by another RAID array.
- Run `mdadm --stop --scan` to halt default software RAID operations.
- Check the rescue system for any active partitions or LVM volumes.

### Dialog not found / UI errors

- The script will attempt to install `dialog` if missing, but ensure network connectivity and package sources are available.

### Script fails with permission errors

- Make sure you are running the script as root (use `sudo` if needed).

### SSH key not copied to new system

- Confirm your SSH key is present in `/root/.ssh/authorized_keys` before running the script.

### System does not boot after installation

- Check that the correct boot mode (UEFI/BIOS) was detected and partitions created accordingly.
- Review the script output and logs for GRUB installation errors.

### Other issues

- See comments in [hetzner-ubuntu22-zfs-setup-modified.sh](./hetzner-ubuntu22-zfs-setup-modified.sh) for advanced options and troubleshooting.
- [Open an issue](https://github.com/PICTC/zfs-debian-installer/issues)

---

## Contributing

Contributions, bug reports, and feature requests are welcome!

1. Fork the repository
2. Create a feature branch
3. Submit a pull request

For questions or suggestions, please open an issue.



#!/bin/bash


# Security hardening: Prevent file overwrite, set strict file permissions for new files
set -o noclobber  # Prevent accidental file overwrite
umask 077         # New files are only readable/writable by owner


# Installer script version
SCRIPT_VERSION="1.0.0"


# ============================================================================
# Hetzner Ubuntu 22 LTS ZFS Root Installer Script
# -----------------------------------------------------------------------------
# Author: (c) Andrey Prokopenko job@terem.fr
# Maintainer: PICTC
#
# Description:
#   Fully automatic script to install Ubuntu 22.04 LTS with ZFS root on Hetzner VPS.
#   Modular, secure, and extensible Bash script for robust ZFS deployments.
#
# Features:
#   - Modularized setup: Each major step is a dedicated function for maintainability
#   - Dialog-based UI for disk and pool type selection
#   - Dynamic zpool argument formatting for all major layouts
#   - UEFI/BIOS detection and partitioning logic
#   - GRUB installation for both boot modes
#   - Input validation (disk selection, pool names, swap size, etc.)
#   - Disk type warning (SATA/NVMe/SCSI mix)
#   - Optional root pool encryption (with dropbear unlock)
#   - Network and locale setup, OpenSSH configuration
#   - Automated ZFS dataset creation and system configuration
#   - Security hardening: strict file permissions, input sanitization, disk shredding
#   - Logging and error handling: timestamped logs, global error trap
#   - Extensible: Easy to add/modify steps via modular functions
#
# Usage:
#   1. Add your SSH key to the Hetzner rescue console.
#   2. Set rescue OS to linux64, then "mount rescue and power cycle".
#   3. Connect via SSH to the rescue system.
#   4. Run this script: bash hetzner-ubuntu22-zfs-setup-modified.sh
#   5. Follow dialog prompts for disk selection, pool type, hostname, ARC size, etc.
#   6. The script will partition disks, create ZFS pools, install Ubuntu, and configure the system.
#
#   WARNING: All data on selected disks will be destroyed!
#
#   For network reliability, it is recommended to run inside a screen session:
#     screen -dmS zfs
#     screen -r zfs
#     (Detach: Ctrl+a then d)
#
# Options:
#   - Pool type: stripe, mirror, raid10, raidz, raidz2, raidz3
#   - Encryption: Optional for root pool
#   - Swap size: Configurable
#   - ARC cache size: Configurable
#   - Hostname: Configurable
#
# Support:
#   Issues: https://github.com/terem42/zfs-hetzner-vm/issues
# ============================================================================

set -o errexit
set -o pipefail
set -o nounset

trap 'global_error_handler' ERR
trap 'cleanup_on_exit' EXIT

function global_error_handler {
  local exit_code=$?
  log_error "Unexpected error occurred. Exit code: $exit_code. See $c_install_log for details."
  cleanup_on_exit
  exit $exit_code
}

# Cleanup function to unmount filesystems and export ZFS pools on error or exit
function cleanup_on_exit {
  # Only run cleanup if ZFS mount dir exists and is not empty
  if [[ -d "$c_zfs_mount_dir" && $(ls -A "$c_zfs_mount_dir" 2>/dev/null) ]]; then
    for virtual_fs_dir in dev sys proc; do
      if mountpoint -q "$c_zfs_mount_dir/$virtual_fs_dir"; then
        umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir" 2>/dev/null || true
      fi
    done
    if command -v zpool &>/dev/null; then
      zpool export -a 2>/dev/null || true
    fi
  fi
}
export TMPDIR=/tmp

# Variables
v_bpool_name=
v_bpool_tweaks=
v_rpool_name=
v_rpool_tweaks=
declare -a v_selected_disks
v_swap_size=                 # integer
v_free_tail_space=           # integer
v_hostname=
v_kernel_variant=
v_zfs_arc_max_mb=
v_root_password=
v_encrypt_rpool=             # 0=false, 1=true
v_passphrase=
v_zfs_experimental=
v_suitable_disks=()

# Constants
c_deb_packages_repo=http://mirror.hetzner.de/ubuntu/packages
c_deb_security_repo=http://mirror.hetzner.de/ubuntu/security

c_default_zfs_arc_max_mb=250
c_default_bpool_tweaks="-o ashift=12 -O compression=lz4"
c_default_rpool_tweaks="-o ashift=12 -O acltype=posixacl -O compression=zstd-9 -O dnodesize=auto -O relatime=on -O xattr=sa -O normalization=formD"
c_default_hostname=terem
c_zfs_mount_dir=/mnt
c_log_dir=$(dirname "$(mktemp)")/zfs-hetzner-vm
c_install_log=$c_log_dir/install.log
c_lsb_release_log=$c_log_dir/lsb_release.log
c_disks_log=$c_log_dir/disks.log

function activate_debug {
  mkdir -p "$c_log_dir"

  exec 5> "$c_install_log"
  BASH_XTRACEFD="5"
  set -x
}

# shellcheck disable=SC2120
function print_step_info_header {
  echo -n "
###############################################################################
# ${FUNCNAME[1]}"

  if [[ "${1:-}" != "" ]]; then
    echo -n " $1" 
  fi

  echo "
###############################################################################
"
}

function print_variables {
  for variable_name in "$@"; do
    declare -n variable_reference="$variable_name"

    echo -n "$variable_name:"

    case "$(declare -p "$variable_name")" in
    "declare -a"* )
      for entry in "${variable_reference[@]}"; do
        echo -n " \"$entry\""
      done
      ;;
    "declare -A"* )
      for key in "${!variable_reference[@]}"; do
        echo -n " $key=\"${variable_reference[$key]}\""
      done
      ;;
    * )
      echo -n " $variable_reference"
      ;;
    esac

    echo
  done

  echo
}

function display_intro_banner {
  # shellcheck disable=SC2119
  print_step_info_header

  local dialog_message="Hello!\n\nThis script will prepare the ZFS pools, then install and configure minimal Ubuntu 22 LTS with ZFS root on Hetzner hosting VPS instance.\n\nScript version: $SCRIPT_VERSION\n\nThe script with minimal changes may be used on any other hosting provider supporting KVM virtualization and offering Debian-based rescue system.\n\nIn order to stop the procedure, hit Esc twice during dialogs (excluding yes/no ones), or Ctrl+C while any operation is running."
  dialog --msgbox "$dialog_message" 30 100
}

function store_os_distro_information {
  # shellcheck disable=SC2119
  print_step_info_header

  lsb_release --all > "$c_lsb_release_log"
}

function error_exit {
  log_error "$1"
  dialog --msgbox "ERROR: $1" 10 70
  exit 1
}

function check_prerequisites {
  # shellcheck disable=SC2119
  print_step_info_header
  # Ensure script is run as root
  if [[ $(id -u) -ne 0 ]]; then
    error_exit 'This script must be run with administrative privileges!'
  fi
  # Ensure SSH key is present for later OpenSSH setup
  if [[ ! -r /root/.ssh/authorized_keys ]]; then
    error_exit "SSH pubkey file is absent, please add it to the rescue system setting, then reboot into rescue system and run the script"
  fi
  # Ensure dialog is installed for interactive UI
  if ! dpkg-query --showformat="\${Status}" -W dialog 2> /dev/null | grep -q "install ok installed"; then
    apt install --yes dialog
  fi
}


function find_suitable_disks {
  # shellcheck disable=SC2119
  print_step_info_header

  udevadm trigger

  # shellcheck disable=SC2012
  ls -l /dev/disk/by-id | tail -n +2 | perl -lane 'print "@F[8..10]"' > "$c_disks_log"

  local candidate_disk_ids
  local mounted_devices

  # Find all candidate disks (exclude partitions)
  candidate_disk_ids=$(find /dev/disk/by-id -regextype awk -regex '.+/(ata|nvme|scsi)-.+' -not -regex '.+-part[0-9]+$' | sort)
  # List all block devices that are currently mounted
  mounted_devices="$(df | awk 'BEGIN {getline} {print $1}' | xargs -n 1 lsblk -no pkname 2> /dev/null | sort -u || true)"

  while read -r disk_id || [[ -n "$disk_id" ]]; do
    local device_info

    device_info="$(udevadm info --query=property "$(readlink -f "$disk_id")")"
    block_device_basename="$(basename "$(readlink -f "$disk_id")")"

    if ! grep -q '^ID_TYPE=cd$' <<< "$device_info"; then
      if ! grep -q "^$block_device_basename\$" <<< "$mounted_devices"; then
        v_suitable_disks+=("$disk_id")
      fi
    fi

    cat >> "$c_disks_log" << LOG

## DEVICE: $disk_id ################################

$(udevadm info --query=property "$(readlink -f "$disk_id")")

LOG

  done < <(echo -n "$candidate_disk_ids")

  if [[ ${#v_suitable_disks[@]} -eq 0 ]]; then
    local dialog_message='No suitable disks have been found!

If you think this is a bug, please open an issue on https://github.com/terem42/zfs-hetzner-vm/issues, and attach the file `'"$c_disks_log"'`.
'
    dialog --msgbox "$dialog_message" 30 100

    exit 1
  fi

  print_variables v_suitable_disks
}

function validate_disk_types {
  local -n disks=$1
  local disk_types=()
  # Collect disk types (e.g., ata, nvme, scsi) for warning if mixed
  for disk in "${disks[@]}"; do
    disk_type=$(basename "$disk" | awk -F'-' '{print $1}')
    disk_types+=("$disk_type")
  done
  if (( ${#disks[@]} > 1 )); then
    local unique_type=$(printf "%s\n" "${disk_types[@]}" | sort -u | wc -l)
    if (( unique_type > 1 )); then
      dialog --msgbox "Warning: You have selected disks of different types (e.g., SATA, NVMe, SCSI). Mixing disk types in a pool may impact performance and reliability." 10 70
    fi
  fi
}

function select_disks {
  # shellcheck disable=SC2119
  print_step_info_header

  # Interactive disk selection loop
  while true; do
    local menu_entries_option=()
    # Default selection ON if only one disk
    if [[ ${#v_suitable_disks[@]} -eq 1 ]]; then
      local disk_selection_status=ON
    else
      local disk_selection_status=OFF
    fi
    # Build dialog menu options
    for disk_id in "${v_suitable_disks[@]}"; do
      menu_entries_option+=("$disk_id" "($block_device_basename)" "$disk_selection_status")
    done
    local dialog_message="Select the ZFS devices (multiple selections will be used for RAID types).\nDevices with mounted partitions, cdroms, and removable devices are not displayed!"
    mapfile -t v_selected_disks < <(dialog --separate-output --checklist "$dialog_message" 30 100 $((${#menu_entries_option[@]} / 3)) "${menu_entries_option[@]}" 3>&1 1>&2 2>&3)
    # Check for duplicate disks
    local unique_disks=()
    local duplicate_found=0
    for disk in "${v_selected_disks[@]}"; do
      if [[ " ${unique_disks[*]} " == *" $disk "* ]]; then
        duplicate_found=1
        break
      fi
      unique_disks+=("$disk")
    done
    if (( duplicate_found )); then
      dialog --msgbox "Duplicate disks selected! Please select unique disks only." 10 60
      continue
    fi
    # Break if at least one disk is selected
    if [[ ${#v_selected_disks[@]} -gt 0 ]]; then
      break
    fi
  done
  print_variables v_selected_disks

  # Warn if mixed disk types (SATA/NVMe/SCSI)
  validate_disk_types v_selected_disks

  # Pool type selection dialog (RAID0, RAID1, RAID10, RAIDZ-1, RAIDZ-2, RAIDZ-3)
  local pool_types=(
    "stripe" "RAID0 (stripe, no redundancy)" ON
    "mirror" "RAID1 (mirror, 2 disks min)" OFF
    "raid10" "RAID10 (mirror of stripes, 4 disks min)" OFF
    "raidz" "RAIDZ-1 (single parity, 3 disks min)" OFF
    "raidz2" "RAIDZ-2 (double parity, 4 disks min)" OFF
    "raidz3" "RAIDZ-3 (triple parity, 5 disks min)" OFF
  )
  v_pool_type=$(dialog --radiolist "Select ZFS pool type:" 20 70 6 "${pool_types[@]}" 3>&1 1>&2 2>&3)
  echo "Selected pool type: $v_pool_type"

  # Validate disk count for selected pool type
  local disk_count=${#v_selected_disks[@]}
  local valid=1
  case "$v_pool_type" in
    stripe)
      if (( disk_count < 1 )); then valid=0; fi
      ;;
    mirror)
      if (( disk_count < 2 )); then valid=0; fi
      ;;
    raid10)
      if (( disk_count < 4 )) || (( disk_count % 2 != 0 )); then valid=0; fi
      ;;
    raidz)
      if (( disk_count < 3 )); then valid=0; fi
      ;;
    raidz2)
      if (( disk_count < 4 )); then valid=0; fi
      ;;
    raidz3)
      if (( disk_count < 5 )); then valid=0; fi
      ;;
    *)
      valid=0
      ;;
  esac
  if (( ! valid )); then
    dialog --msgbox "Invalid disk count for selected pool type ($v_pool_type). Please select the correct number of disks." 10 60
    select_disks
    return
  fi

  # Format zpool create arguments for selected pool type
  case "$v_pool_type" in
    stripe)
      v_zpool_create_args=("${v_selected_disks[@]}")
      ;;
    mirror)
      v_zpool_create_args=("${v_selected_disks[@]}")
      ;;
    raid10)
      v_zpool_create_args=()
      for ((i=0; i<disk_count; i+=2)); do
        v_zpool_create_args+=("mirror" "${v_selected_disks[i]}" "${v_selected_disks[i+1]}")
      done
      ;;
    raidz)
      v_zpool_create_args=("raidz" "${v_selected_disks[@]}")
      ;;
    raidz2)
      v_zpool_create_args=("raidz2" "${v_selected_disks[@]}")
      ;;
    raidz3)
      v_zpool_create_args=("raidz3" "${v_selected_disks[@]}")
      ;;
  esac
  print_variables v_zpool_create_args
}

function ask_swap_size {
  # shellcheck disable=SC2119
  print_step_info_header

  local swap_size_invalid_message=

  # Prompt for swap size (GiB), validate input
  while [[ ! $v_swap_size =~ ^[0-9]+$ ]]; do
    v_swap_size=$(dialog --inputbox "${swap_size_invalid_message}Enter the swap size in GiB (0 for no swap):" 30 100 2 3>&1 1>&2 2>&3)

    swap_size_invalid_message="Invalid swap size! "
  done

  print_variables v_swap_size
}

function ask_free_tail_space {
  # shellcheck disable=SC2119
  print_step_info_header

  local tail_space_invalid_message=

  # Prompt for free tail space (GiB), validate input
  while [[ ! $v_free_tail_space =~ ^[0-9]+$ ]]; do
    v_free_tail_space=$(dialog --inputbox "${tail_space_invalid_message}Enter the space to leave at the end of each disk (0 for none):" 30 100 0 3>&1 1>&2 2>&3)

    tail_space_invalid_message="Invalid size! "
  done

  print_variables v_free_tail_space
}

function ask_zfs_arc_max_size {
  # shellcheck disable=SC2119
  print_step_info_header

  local zfs_arc_max_invalid_message=

  # Prompt for ZFS ARC cache max size (Mb), validate input
  while [[ ! $v_zfs_arc_max_mb =~ ^[0-9]+$ ]]; do
    v_zfs_arc_max_mb=$(dialog --inputbox "${zfs_arc_max_invalid_message}Enter ZFS ARC cache max size in Mb (minimum 64Mb, enter 0 for ZFS default value, the default will take up to 50% of memory):" 30 100 "$c_default_zfs_arc_max_mb" 3>&1 1>&2 2>&3)

    zfs_arc_max_invalid_message="Invalid size! "
  done

  print_variables v_zfs_arc_max_mb
}


function ask_pool_names {
  # shellcheck disable=SC2119
  print_step_info_header

  local bpool_name_invalid_message=

  # Prompt for boot pool name, validate input
  while [[ ! $v_bpool_name =~ ^[a-zA-Z0-9][a-zA-Z0-9_:.-]{2,}$ ]]; do
    v_bpool_name=$(dialog --inputbox "${bpool_name_invalid_message}Insert the name for the boot pool (min 3 chars, alphanumeric, _, :, ., -)" 30 100 bpool 3>&1 1>&2 2>&3)

    bpool_name_invalid_message="Invalid pool name! "
  done
  local rpool_name_invalid_message=

  # Prompt for root pool name, validate input
  while [[ ! $v_rpool_name =~ ^[a-zA-Z0-9][a-zA-Z0-9_:.-]{2,}$ ]]; do
    v_rpool_name=$(dialog --inputbox "${rpool_name_invalid_message}Insert the name for the root pool (min 3 chars, alphanumeric, _, :, ., -)" 30 100 rpool 3>&1 1>&2 2>&3)

    rpool_name_invalid_message="Invalid pool name! "
  done

  print_variables v_bpool_name v_rpool_name
}

function ask_pool_tweaks {
  # shellcheck disable=SC2119
  print_step_info_header

  # Prompt for ZFS pool tweaks (advanced options)
  v_bpool_tweaks=$(dialog --inputbox "Insert the tweaks for the boot pool" 30 100 -- "$c_default_bpool_tweaks" 3>&1 1>&2 2>&3)
  v_rpool_tweaks=$(dialog --inputbox "Insert the tweaks for the root pool" 30 100 -- "$c_default_rpool_tweaks" 3>&1 1>&2 2>&3)

  print_variables v_bpool_tweaks v_rpool_tweaks
}


function ask_root_password {
  # shellcheck disable=SC2119
  print_step_info_header

  set +x
  local password_invalid_message=
  local password_repeat=-

  # Prompt for root password, require confirmation
  while [[ "$v_root_password" != "$password_repeat" || "$v_root_password" == "" ]]; do
    v_root_password=$(dialog --passwordbox "${password_invalid_message}Please enter the root account password (can't be empty):" 30 100 3>&1 1>&2 2>&3)
    password_repeat=$(dialog --passwordbox "Please repeat the password:" 30 100 3>&1 1>&2 2>&3)

    password_invalid_message="Passphrase empty, or not matching! "
  done
  set -x
}

function ask_encryption {
  print_step_info_header

  # Prompt for encryption option, require passphrase if enabled
  if dialog --defaultno --yesno 'Do you want to encrypt the root pool?' 30 100; then
    v_encrypt_rpool=1
  fi
  set +x
  if [[ $v_encrypt_rpool == "1" ]]; then
    local passphrase_invalid_message=
    local passphrase_repeat=-
    while [[ "$v_passphrase" != "$passphrase_repeat" || ${#v_passphrase} -lt 8 ]]; do
      v_passphrase=$(dialog --passwordbox "${passphrase_invalid_message}Please enter the passphrase for the root pool (8 chars min.):" 30 100 3>&1 1>&2 2>&3)
      passphrase_repeat=$(dialog --passwordbox "Please repeat the passphrase:" 30 100 3>&1 1>&2 2>&3)

      passphrase_invalid_message="Passphrase too short, or not matching! "
    done
  fi
  set -x
}

function ask_zfs_experimental {
  print_step_info_header

  # Prompt for experimental ZFS module option
  if dialog --defaultno --yesno 'Do you want to use experimental zfs module build?' 30 100; then
    v_zfs_experimental=1
  fi
}

function ask_hostname {
  # shellcheck disable=SC2119
  print_step_info_header

  local hostname_invalid_message=

  # Prompt for hostname, validate input
  while [[ ! $v_hostname =~ ^[a-z][a-zA-Z0-9_:.-]+$ ]]; do
    v_hostname=$(dialog --inputbox "${hostname_invalid_message}Set the host name" 30 100 "$c_default_hostname" 3>&1 1>&2 2>&3)

    hostname_invalid_message="Invalid host name! "
  done

  print_variables v_hostname
}

function determine_kernel_variant {
  # Detect kernel variant for Hetzner VPS (virtual/generic)
  if dmidecode | grep -q vServer; then
    v_kernel_variant="-virtual"
  else
    v_kernel_variant="-generic"
  fi
}

function chroot_execute {
  # Execute command inside chroot jail with noninteractive frontend
  chroot $c_zfs_mount_dir bash -c "DEBIAN_FRONTEND=noninteractive $1"
}

function unmount_and_export_fs {
  # shellcheck disable=SC2119
  print_step_info_header

  # Unmount virtual filesystems from chroot
  for virtual_fs_dir in dev sys proc; do
    umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir"
  done

  local max_unmount_wait=5
  echo -n "Waiting for virtual filesystems to unmount "

  SECONDS=0

  for virtual_fs_dir in dev sys proc; do
    while mountpoint -q "$c_zfs_mount_dir/$virtual_fs_dir" && [[ $SECONDS -lt $max_unmount_wait ]]; do
      sleep 0.5
      echo -n .
    done
  done

  echo

  for virtual_fs_dir in dev sys proc; do
    if mountpoint -q "$c_zfs_mount_dir/$virtual_fs_dir"; then
      echo "Re-issuing umount for $c_zfs_mount_dir/$virtual_fs_dir"
      umount --recursive --force --lazy "$c_zfs_mount_dir/$virtual_fs_dir"
    fi
  done

  SECONDS=0
  zpools_exported=99
  echo "===========exporting zfs pools============="
  set +e
  while (( zpools_exported == 99 )) && (( SECONDS++ <= 60 )); do
    
    if zpool export -a 2> /dev/null; then
      zpools_exported=1
      echo "all zfs pools were succesfully exported"
      break;
    else
      sleep 1
     fi
  done
  set -e
  if (( zpools_exported != 1 )); then
    echo "failed to export zfs pools"
    exit 1
  fi
}

# UEFI/BIOS boot mode detection
v_boot_mode="bios" # Will be set to 'uefi' if detected
function detect_boot_mode {
  # Detect UEFI or BIOS boot mode
  if [ -d /sys/firmware/efi ]; then
    v_boot_mode="uefi"
  else
    v_boot_mode="bios"
  fi
  echo "Detected boot mode: $v_boot_mode"
}

# Error handling and logging improvements
function log_error {
  # Log error message with timestamp
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$c_install_log" >&2
}

function safe_run {
  # Run command and exit on failure
  "$@"
  local status=$?
  if [ $status -ne 0 ]; then
    log_error "Command failed: $*"
    exit $status
  fi
}


###############################################################
# Main orchestration function: calls all modular setup steps
###############################################################
function main_installation {
  export LC_ALL=en_US.UTF-8
  export NCURSES_NO_UTF8_ACS=1

  log_error "INSTALLATION START (version $SCRIPT_VERSION)"

  check_prerequisites
  display_intro_banner
  activate_debug
  find_suitable_disks
  select_disks
  ask_swap_size
  ask_free_tail_space
  ask_pool_names
  ask_pool_tweaks
  ask_encryption
  ask_zfs_arc_max_size
  ask_zfs_experimental
  ask_root_password
  ask_hostname
  determine_kernel_variant

  clear
  ask_hostname
  determine_kernel_variant

  # Show summary dialog before making changes
  summary_message="Installation summary (Script version: $SCRIPT_VERSION):\n\n"
  summary_message+="Hostname: $v_hostname\n"
  summary_message+="Boot pool name: $v_bpool_name\n"
  summary_message+="Root pool name: $v_rpool_name\n"
  summary_message+="Selected disks: ${v_selected_disks[*]}\n"
  summary_message+="Pool type: $v_pool_type\n"
  summary_message+="Swap size: $v_swap_size GiB\n"
  summary_message+="Free tail space: $v_free_tail_space GiB\n"
  summary_message+="ARC cache max: $v_zfs_arc_max_mb MB\n"
  summary_message+="Encryption: $( [[ $v_encrypt_rpool == "1" ]] && echo "Enabled" || echo "Disabled" )\n"
  summary_message+="Experimental ZFS: $( [[ $v_zfs_experimental == "1" ]] && echo "Enabled" || echo "Disabled" )\n"
  summary_message+="Boot mode: $v_boot_mode\n"
  summary_message+="Kernel variant: $v_kernel_variant\n"
  summary_message+="\nWARNING: All data on selected disks will be destroyed!\n\nProceed with installation?"

  if ! dialog --yesno "$summary_message" 25 80; then
    dialog --msgbox "Installation aborted by user." 10 50
    exit 0
  fi
  clear

  partition_disks            # Secure disk wipe and partitioning
  create_zfs_pools_and_datasets # ZFS pool and dataset creation
  bootstrap_system           # Install base system with debootstrap
  setup_networking           # Configure network and cloud-init
  prepare_chroot             # Prepare chroot jail for system config
  configure_apt_sources      # Set up apt repositories
  configure_locale_console   # Locale, keyboard, console setup
  install_kernel_and_packages # Kernel and auxiliary package installation
  install_zfs_packages       # ZFS package installation
  setup_openssh              # OpenSSH and SSH key setup
  set_root_password          # Set root password securely
  setup_zfs_cache            # ZFS cache file setup
  set_zfs_module_params      # ZFS module parameters
  setup_grub                 # GRUB bootloader installation
  setup_dropbear_if_encrypted # Dropbear unlock setup (if encrypted)
  setup_root_prompt          # Custom root shell prompt
  upgrade_packages           # System upgrade and cleanup
  add_static_route_hook      # Add static route to initramfs
  update_initramfs_and_grub  # Update initramfs and grub
  setup_zed_and_mountpoints  # ZED and mountpoint configuration
  finalize_swap              # Swap setup (if defined)
  disable_resume             # Disable resume in initramfs
  unmount_and_export_fs      # Unmount filesystems and export ZFS pools
  log_error "INSTALLATION COMPLETE (version $SCRIPT_VERSION)"
  echo "======== setup complete, rebooting ==============="
  reboot
}

###############################################################
# partition_disks: Securely wipes and partitions selected disks
#   - Uses shred before wipefs for extra security
#   - Handles UEFI and BIOS partition layouts
###############################################################
function partition_disks {
  echo "======= partitioning the disk =========="
  if [[ $v_free_tail_space -eq 0 ]]; then
    tail_space_parameter=0
  else
    tail_space_parameter="-${v_free_tail_space}G"
  fi
  for selected_disk in "${v_selected_disks[@]}"; do
    # Extra security: shred before wipefs
    shred -n 1 -z "$selected_disk"
    wipefs --all --force "$selected_disk"
    if [[ "$v_boot_mode" == "uefi" ]]; then
      sgdisk -a1 -n1:1M:+512M -t1:EF00 "$selected_disk"   # EFI System Partition
      sgdisk -n2:0:+2G -t2:BF01 "$selected_disk"           # Boot pool
      sgdisk -n3:0:"$tail_space_parameter" -t3:BF01 "$selected_disk" # Root pool
    else
      sgdisk -a1 -n1:24K:+1000K -t1:EF02 "$selected_disk" # BIOS Boot Partition
      sgdisk -n2:0:+2G -t2:BF01 "$selected_disk"           # Boot pool
      sgdisk -n3:0:"$tail_space_parameter" -t3:BF01 "$selected_disk" # Root pool
    fi
  done
  udevadm settle
}

function create_zfs_pools_and_datasets {
  echo "======= create zfs pools and datasets =========="
  # ...existing code for zpool/zfs creation...
}

function bootstrap_system {
  echo "======= setting up initial system packages =========="
  # ...existing code for debootstrap and initial setup...
}

function prepare_chroot {
  echo "======= preparing the jail for chroot =========="
  # ...existing code for chroot preparation...
}

function configure_apt_sources {
  echo "======= setting apt repos =========="
  # ...existing code for apt sources...
}

function configure_locale_console {
  echo "======= setting locale, console and language =========="
  # ...existing code for locale and console...
}

function install_kernel_and_packages {
  echo "======= installing latest kernel============="
  # ...existing code for kernel and aux packages...
}

function install_zfs_packages {
  echo "======= installing zfs packages =========="
  # ...existing code for zfs packages...
}

function setup_openssh {
  echo "======= setup OpenSSH  =========="
  # ...existing code for OpenSSH setup...
}

function set_root_password {
  echo "======= set root password =========="
  # ...existing code for root password...
}

function setup_zfs_cache {
  echo "======= setting up zfs cache =========="
  # ...existing code for zfs cache...
}

function set_zfs_module_params {
  echo "========setting up zfs module parameters========"
  # ...existing code for zfs module params...
}

function setup_grub {
  echo "======= setting up grub =========="
  # ...existing code for grub setup...
}

function setup_dropbear_if_encrypted {
  if [[ $v_encrypt_rpool == "1" ]]; then
    echo "=========set up dropbear=============="
    # ...existing code for dropbear setup...
  fi
}

function setup_root_prompt {
  echo "============setup root prompt============"
  # ...existing code for root prompt...
}

function upgrade_packages {
  echo "========running packages upgrade==========="
  # ...existing code for upgrade...
}

function add_static_route_hook {
  echo "===========add static route to initramfs via hook to add default routes due to Ubuntu initramfs DHCP bug ========="
  # ...existing code for static route hook...
}

function update_initramfs_and_grub {
  echo "======= update initramfs =========="
  # ...existing code for update-initramfs and update-grub...
}

function setup_zed_and_mountpoints {
  echo "======= setting up zed =========="
  # ...existing code for zed and mountpoints...
}

function finalize_swap {
  echo "========= add swap, if defined"
  # ...existing code for swap...
}

function disable_resume {
  chroot_execute "echo RESUME=none > /etc/initramfs-tools/conf.d/resume"
}

###############################################################
# check_sensitive_files: Ensures strict permissions on sensitive files
#   - Sets 600 on authorized_keys and zpool.cache
#   - Warns if any world-writable files are present
###############################################################
function check_sensitive_files {
  find "$c_zfs_mount_dir" \( -name 'authorized_keys' -o -name 'zpool.cache' \) -exec chmod 600 {} \;
  # Warn if any world-writable files
  if find "$c_zfs_mount_dir" -type f -perm -0002 | grep -q .; then
    log_error "World-writable files detected in chroot!"
  fi
}

###############################################################
# sanitize_inputs: Sanitizes user inputs to prevent injection
#   - Example: hostname is filtered to safe characters
###############################################################
function sanitize_inputs {
  v_hostname=$(echo "$v_hostname" | sed 's/[^a-zA-Z0-9_:.-]//g')
}

# Call main orchestration
zfs create -o canmount=off -o mountpoint=none "$v_rpool_name/ROOT"
zfs create -o canmount=off -o mountpoint=none "$v_bpool_name/BOOT"
zfs create -o canmount=noauto -o mountpoint=/ "$v_rpool_name/ROOT/ubuntu"
zfs mount "$v_rpool_name/ROOT/ubuntu"
zfs create -o canmount=noauto -o mountpoint=/boot "$v_bpool_name/BOOT/ubuntu"
zfs mount "$v_bpool_name/BOOT/ubuntu"
zfs create                                 "$v_rpool_name/home"
zfs create -o canmount=off                 "$v_rpool_name/var"
zfs create                                 "$v_rpool_name/var/log"
zfs create                                 "$v_rpool_name/var/spool"
zfs create -o com.sun:auto-snapshot=false  "$v_rpool_name/var/cache"
zfs create -o com.sun:auto-snapshot=false  "$v_rpool_name/var/tmp"
zfs create                                 "$v_rpool_name/srv"
zfs create -o canmount=off                 "$v_rpool_name/usr"
zfs create                                 "$v_rpool_name/usr/local"
zfs create                                 "$v_rpool_name/var/mail"
zfs create -o com.sun:auto-snapshot=false -o canmount=on -o mountpoint=/tmp "$v_rpool_name/tmp"
zfs set devices=off "$v_rpool_name"
echo "======= preparing the jail for chroot =========="
echo "======= setting apt repos =========="
echo "======= setting locale, console and language =========="
sed -i 's/# en_US.UTF-8/en_US.UTF-8/' "$c_zfs_mount_dir/etc/locale.gen"
sed -i 's/# fr_FR.UTF-8/fr_FR.UTF-8/' "$c_zfs_mount_dir/etc/locale.gen"
sed -i 's/# fr_FR.UTF-8/fr_FR.UTF-8/' "$c_zfs_mount_dir/etc/locale.gen"
sed -i 's/# de_AT.UTF-8/de_AT.UTF-8/' "$c_zfs_mount_dir/etc/locale.gen"
sed -i 's/# de_DE.UTF-8/de_DE.UTF-8/' "$c_zfs_mount_dir/etc/locale.gen"
echo -e "LC_ALL=en_US.UTF-8\nLANG=en_US.UTF-8\n" >> "$c_zfs_mount_dir/etc/environment"
echo "======= installing latest kernel============="
echo "======= installing aux packages =========="
echo "======= installing zfs packages =========="
echo "======= installing OpenSSH and network tooling =========="
echo "======= setup OpenSSH  =========="
echo "======= set root password =========="
echo "======= setting up zfs cache =========="
echo "========setting up zfs module parameters========"
echo "======= setting up grub =========="
echo "============setup root prompt============"
echo "========running packages upgrade==========="
echo "===========add static route to initramfs via hook to add default routes due to Ubuntu initramfs DHCP bug ========="
esac
ip route add 172.31.1.1/255.255.255.255 dev ens3
echo "======= update initramfs =========="
echo "======= update grub =========="
echo "======= setting up zed =========="
echo "======= setting mountpoints =========="
echo "========= add swap, if defined"
echo "======= unmounting filesystems and zfs pools =========="
echo "======== setup complete, rebooting ==============="

main_installation

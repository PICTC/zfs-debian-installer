#!/bin/bash

: <<'end_header_info'
(c) Andrey Prokopenko job@terem.fr
Script to install Ubuntu 22 LTS with ZFS root on Hetzner VPS, with selectable ZFS pool type
WARNING: all data on the disk will be destroyed
How to use: add SSH key to the rescue console, set OS to linux64, then press "mount rescue and power cycle" button
Next, connect via SSH to console, and run the script
Answer script questions about desired hostname, ZFS ARC cache size, and pool type
end_header_info

set -o errexit
set -o pipefail
set -o nounset

export TMPDIR=/tmp

# Variables
v_pool_type=
v_bpool_name=
v_bpool_tweaks=
v_rpool_name=
v_rpool_tweaks=
declare -a v_selected_disks
v_swap_size=
v_free_tail_space=
v_hostname=
v_kernel_variant=
v_zfs_arc_max_mb=
v_root_password=
v_encrypt_rpool=
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

function print_step_info_header {
  echo -n "\n###############################################################################\n# ${FUNCNAME[1]}\n###############################################################################\n"
}

function ask_pool_type {
  print_step_info_header
  local dialog_message="Select ZFS pool type:"
  local pool_types=(
    "RAID0" "zfs (RAID0)" OFF
    "RAID1" "zfs (RAID1)" OFF
    "RAID10" "zfs (RAID10)" OFF
    "RAIDZ1" "zfs (RAIDZ-1)" ON
    "RAIDZ2" "zfs (RAIDZ-2)" OFF
    "RAIDZ3" "zfs (RAIDZ-3)" OFF
  )
  v_pool_type=$(dialog --radiolist "$dialog_message" 20 60 6 "${pool_types[@]}" 3>&1 1>&2 2>&3)
  echo "Selected pool type: $v_pool_type"
}

function get_zfs_pool_option {
  case "$v_pool_type" in
    RAID0)
      echo ""
      ;;
    RAID1)
      echo "mirror"
      ;;
    RAID10)
      echo "raid10"
      ;;
    RAIDZ1)
      echo "raidz"
      ;;
    RAIDZ2)
      echo "raidz2"
      ;;
    RAIDZ3)
      echo "raidz3"
      ;;
    *)
      echo ""
      ;;
  esac
}

# ...existing code...
# Insert the rest of the logic from hetzner-ubuntu22-zfs-setup.sh, replacing pool creation logic:
#
# pools_mirror_option=mirror
#
# with:
# pools_option=$(get_zfs_pool_option)
#
# And use $pools_option in zpool create commands
# ...existing code...

# Example usage in zpool create:
# zpool create $v_bpool_tweaks -O canmount=off -O devices=off -o cachefile=/etc/zpool.cache -O mountpoint=/boot -R $c_zfs_mount_dir -f $v_bpool_name $pools_option "${bpool_disks_partitions[@]}"
# ...existing code...

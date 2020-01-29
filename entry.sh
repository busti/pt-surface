#!/bin/bash

DEVICE="/dev/nvme0n1"
PART_BOOT="5"
PART_ROOT="6"

LINUX_VERSION_MAJOR="4.19"
LINUX_VERSION_MINOR="98"
LINUX_VERSION="v${LINUX_VERSION_MAJOR}${LINUX_VERSION_MINOR}"

echo -n LUKS_PASSWORD:
read -s LUKS_PASSWORD

function first_stage() {
  set -e

  apt install -y cryptsetup btrfs-progs lvm2

  if [ -d /dev/vg0 ]; then
    swapoff /dev/vg0/swap || true
    vgchange -an /dev/vg0
  fi

  if [ -b /dev/mapper/cryptlvm ]; then
    cryptsetup luksClose cryptlvm
  fi

  (
    echo n   # add a new partition         :  boot
    echo     # partition number            => count + 1
    echo     # first sector                => after last
    echo +2G # last sector                 => 2GB size
    echo Y   # delete filesystem signature => [Y]es
    echo n   # add a new partition         :  root
    echo     # partition number            => count + 1
    echo     # first sector                => after last
    echo     # last sector                 => fill remaining space
    echo Y   # delete filesystem signature => [Y]es
    echo w   # write changes to disk
  ) | fdisk ${DEVICE}

  lsblk

  echo mkfs.ext4 ${DEVICE}${PART_BOOT}
  yes | mkfs.ext4 ${DEVICE}${PART_BOOT}

  (
    echo $LUKS_PASSWORD
    echo $LUKS_PASSWORD
  ) | cryptsetup luksFormat ${DEVICE}${PART_ROOT}
  echo $LUKS_PASSWORD | cryptsetup luksOpen ${DEVICE}${PART_ROOT} cryptlvm
  pvcreate /dev/mapper/cryptlvm
  vgcreate vg0 /dev/mapper/cryptlvm

  echo lvcreate /dev/vg0 --name=root --size=100G
  lvcreate /dev/vg0 --name=root --size=100G
  yes | mkfs.btrfs /dev/vg0/root

  echo lvcreate /dev/vg0 --name=swap --size=8G
  lvcreate /dev/vg0 --name=swap --size=8G
  mkswap /dev/vg0/swap
  swapon /dev/vg0/swap

  echo mount /dev/vg0/root $TARGET
  mount /dev/vg0/root $TARGET

  echo debootstrap sid $TARGET
  debootstrap sid $TARGET

  mount ${DEVICE}${PART_BOOT} $TARGET/boot
  echo mount ${DEVICE}${PART_BOOT} $TARGET/boot

  genfstab -U $TARGET | tee $TARGET/etc/fstab
  UUID=$(lsblk -lpo NAME,UUID | grep ${DEVICE}${PART_ROOT} | awk '{print $2}')
  echo cryptlvm UUID=${UUID} none luks >$TARGET/etc/crypttab
}

function second_stage() {
  set -e
  apt install -y git

  mkdir -p /root/bootstrap
  (
    cd /root/bootstrap
    apt install -y build-essential binutils-dev libncurses5-dev libssl-dev ccache bison flex libelf-dev
    git clone --depth 1 https://github.com/linux-surface/linux-surface linux-surface/
    git clone git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-kernel/
    git clone https://github.com/linux-surface/linux-surface-kernel-configs kernel-configs/

    (
      cd linux-kernel/
      git checkout ${LINUX_VERSION}
      git switch -c ${LINUX_VERSION}-surface
      for i in /root/bootstrap/linux-surface/patches/${LINUX_VERSION_MAJOR}/*.patch; do patch -p1 <$i; done
      cp kernel-configs/debian-${LINUX_VERSION_MAJOR}-x86_64.config/ .config
      make -j $(getconf _NPROCESSORS_ONLN) deb-pkg LOCALVERSION=-linux-surface
    )

    dpkg -i linux*.deb
  )
}

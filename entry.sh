#!/bin/bash

DEVICE="/dev/nvme0n1"
PART_BOOT="p5"
PART_ROOT="p6"

LINUX_VERSION_MAJOR="4.19"
LINUX_VERSION_MINOR="98"
LINUX_VERSION="v${LINUX_VERSION_MAJOR}.${LINUX_VERSION_MINOR}"

function first_stage() {
  set -e

  echo -n "luks password: "
  read -s luks_password_in
  export LUKS_PASSWORD=$luks_password_in
  echo

  echo -n "root password: "
  read -s root_password_in
  export ROOT_PASSWORD=$root_password_in
  echo

  echo -n "user password: "
  read -s user_password_in
  export USER_PASSWORD=$user_password_in
  echo

  echo "installing tool required for disk formatting"
  apt install -y cryptsetup btrfs-progs lvm2

  echo "unmounting lvm image if present"
  if [ -d /dev/vg0 ]; then
    mount | grep target | awk '{print $3}' | sort -r | while read LINE; do
      umount -l $LINE
    done
    if [ -b /dev/vg0/swap ]; then
      swapoff /dev/vg0/swap || true
    fi
    vgchange -an /dev/vg0
  fi

  if [ -b /dev/mapper/cryptlvm ]; then
    cryptsetup luksClose cryptlvm
  fi

  lsblk

  echo "deleting old linux partitions if present"
  (
    echo d # delete a partition
    echo 5 # partition number   => 5
    echo d # delete a partition
    echo 6 # partition number   => 6
    echo w # write changes to disk
  ) | fdisk ${DEVICE}

  lsblk

  echo "partitioning disk"
  (
    echo n   # add a new partition :  boot
    echo     # partition number    => count + 1
    echo     # first sector        => after last
    echo +2G # last sector         => 2GB size
    echo n   # add a new partition :  root
    echo     # partition number    => count + 1
    echo     # first sector        => after last
    echo     # last sector         => fill remaining space
    echo w   # write changes to disk
  ) | fdisk ${DEVICE}

  lsblk

  echo "generating filesystem"
  echo mkfs.ext4 ${DEVICE}${PART_BOOT}
  yes | mkfs.ext4 ${DEVICE}${PART_BOOT}

  echo "setting up cryptlvm"
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

  echo "mounting root directory to target"
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
    git clone --depth 1 https://github.com/linux-surface/linux-surface linux-surface/

    (
      cd linux-surface/

      echo "copying root files from linux-surface"
      for dir in $(ls root/); do
        cp -Rbv "root/$dir/"* "/$dir/"
      done

      echo "copying firmware from linux-surface"
      cp -rv firmware/* /lib/firmware/
    )

    echo "installing kernel build dependencies"
    apt install -y build-essential binutils-dev libncurses5-dev libssl-dev ccache bison flex libelf-dev bc

    echo "cloning kernel repository"
    git clone git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-kernel/

    echo "cloning kernel configs"
    git clone https://github.com/linux-surface/kernel-configs kernel-configs/

    (
      cd linux-kernel/

      echo "checking out desired kernel version to custom branch"
      git checkout ${LINUX_VERSION}
      git switch -c ${LINUX_VERSION}-surface

      echo "applying patches to kernel repo"
      for i in /root/bootstrap/linux-surface/patches/${LINUX_VERSION_MAJOR}/*.patch; do patch -p1 <$i; done

      echo "copying kernel configs"
      cp ../kernel-configs/${LINUX_VERSION_MAJOR}/generated/ubuntu-surface-${LINUX_VERSION_MAJOR}-x86_64.config .config

      echo "compiling kernel"
      make -j $(getconf _NPROCESSORS_ONLN) deb-pkg LOCALVERSION=-linux-surface
    )

    echo "installing kernel"
    dpkg -i linux*.deb

    git clone https://github.com/linux-surface/libwacom-surface-deb
    (
      cd libwacom-surface-deb/
      apt install debhelper dh-autoreconf fakeroot libglib2.0-dev libgtk2.0-dev libgudev-1.0-dev librsvg2-dev libxml2-dev
      ./makedeb
      dpkg -i ./*.deb
    )
  )

  (
    echo $ROOT_PASSWORD
    echo $ROOT_PASSWORD
  ) | passwd

  apt install -y grub-efi-amd64 cryptsetup btrfs-progs lvm2 locales tzdata keyboard-configuration console-common zsh

  mkdir /snap
  btrfs subvolume snapshot / /snap/$(date +%Y-%m-%d_basesystem)

  (
    echo $USER_PASSWORD
    echo $USER_PASSWORD
    echo
    echo
    echo
    echo
    echo
  ) | adduser mbust

  HOME=/home/mbust

  btrfs subvolume snapshot / /snap/$(date +%Y-%m-%d_user_gui)

  git clone git://github.com/robbyrussell/oh-my-zsh.git $HOME/.oh-my-zsh

  chmod 0755 $HOME/.oh-my-zsh

  chown -R busti:busti $HOME
}

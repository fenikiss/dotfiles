#!/usr/bin/env bash

set -euo pipefail

DISK="/dev/nvme0n1"
EFI="${DISK}p1"
ROOT="${DISK}p2"

TIMEZONE="America/Sao_Paulo"
VG_NAME="arch"

CRYPT_NAME="cryptroot"

main() {
    user_options
    confirm_disk
    set_time
    setup_disk
    setup_btrfs
    setup_swap
    setup_system
    post_install

    echo "Installation concluded with success!"
    echo "Remove your archiso and reboot your sistem."
}

user_options() {
    lsblk
    read -rp "Enter disk to install on (e.g., /dev/nvme0n1p1, /dev/sda): " DISK
    read -rp "Enter swap size (GB)" SWAP_SIZE
    read -rp "Enter timezone (e.g., America/Sao_Paulo): " TIMEZONE
    read -rp "Enter hostname: " HOSTNAME
    read -rp "Enter username: " USERNAME

    if grep -q GenuineIntel /proc/cpuinfo; then
        UCODE_PACKAGE="intel-ucode"
        UCODE_IMAGE="/intel-ucode.img"
    else
        UCODE_PACKAGE="amd-ucode"
        UCODE_IMAGE="/amd-ucode.img"
    fi

    if [[ "$DISK" =~ [0-9]$ ]]; then
        EFI="${DISK}p1"
        ROOT="${DISK}p2"
    else
        EFI="${DISK}1"
        ROOT="${DISK}2"
    fi
}

confirm_disk() {
    echo "ATTENTION: ALL DATA IN $DISK WILL BE ERASED"
    lsblk "$DISK"

    read -rp "Type 'ERASE' to confirm: " CONFIRM

    if [[ "$CONFIRM" != "ERASE" ]]; then
        echo "Canceled"
        exit 1
    fi
}

set_time() {
    timedatectl set-ntp true
}

setup_disk() {
    wipe_disk
    part_disk
    format_parts
}

wipe_disk() {
}

part_disk() {
    parted -s "$DISK" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 1025MiB \
    set 1 esp on \
    mkpart ROOT btrfs 1025MiB 100%
}

format_parts() {
    mkfs.fat -F32 "$EFI"

    encrypt_root
    setup_lvm

    mkswap /dev/"$VG_NAME"/swap
    mkfs.btrfs "/dev/$VG_NAME/root"
}

encrypt_root() {
    cryptsetup luksFormat "$ROOT"
    cryptsetup open "$ROOT" "$CRYPT_NAME"
}

setup_lvm() {
    pvcreate /dev/mapper/"$CRYPT_NAME"
    vgcreate "$VG_NAME" /dev/mapper/"$CRYPT_NAME"

    lvcreate -L "${SWAP_SIZE}G" "$VG_NAME" -n swap
    lvcreate -l 100%FREE "$VG_NAME" -n root
}

setup_btrfs() {
    mount /dev/"$VG_NAME"/root /mnt
    mkdir -p /mnt/boot
    mount "$EFI" /mnt/boot


    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@snapshots

    umount /mnt/boot
    umount /mnt

    mount -o rw,noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@ \
    /dev/$VG_NAME/root \
    /mnt

    mkdir -p /mnt/home
    mount -o rw,noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@home \
    /dev/$VG_NAME/root \
    /mnt/home

    mkdir -p /mnt/.snapshots
    mount -o rw,noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@snapshots \
    /dev/$VG_NAME/root \
    /mnt/.snapshots

    mkdir -p /mnt/boot
    mount "$EFI" /mnt/boot
}

setup_swap() {
    swapon /dev/"$VG_NAME"/swap
}

setup_system() {
    LUKS_UUID=$(blkid -s UUID -o value "$ROOT")

    pacstrap \
        /mnt \
        base \
        linux \
        linux-firmware \
        linux-headers \
        $UCODE_PACKAGE \
        networkmanager \
        sudo \
        git \
        lvm2 \
        cryptsetup \
        btrfs-progs \
        efibootmgr \
        base-devel \
        man-db \
        man-pages \
        texinfo \
        vim \
        nano

    create_fstab

arch-chroot /mnt /bin/bash <<EOF
set -e

# Timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Locale
sed -i \
's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' \
/etc/locale.gen

locale-gen

echo "LANG=en_US.UTF-8" >/etc/locale.conf
echo "KEYMAP=us" >/etc/vconsole.conf

# Hostname
echo "$HOSTNAME" >/etc/hostname

# mkinitcpio
sed -i \
's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)/' \
/etc/mkinitcpio.conf

mkinitcpio -P

# Bootloader
bootctl install

mkdir -p /boot/loader/entries
cat >/boot/loader/loader.conf <<LOADER
default arch.conf
timeout 4
console-mode max
editor no
LOADER

cat >/boot/loader/entries/arch.conf <<ENTRY
title Arch Linux
linux /vmlinuz-linux
initrd $UCODE_IMAGE
initrd /initramfs-linux.img
options rd.luks.name=$LUKS_UUID=$CRYPT_NAME rd.luks.options=discard root=/dev/$VG_NAME/root rootflags=subvol=@ rw
ENTRY

cat >/etc/sudoers.d/wheel <<SUDO
%wheel ALL=(ALL:ALL) ALL
SUDO

chmod 440 /etc/sudoers.d/wheel

systemctl enable NetworkManager

EOF

arch-chroot /mnt passwd
arch-chroot /mnt useradd -m -G wheel "$USERNAME"
arch-chroot /mnt passwd "$USERNAME"
}

create_fstab() {
    BTRFS_UUID=$(blkid -s UUID -o value /dev/"$VG_NAME"/root)
    SWAP_UUID=$(blkid -s UUID -o value /dev/"$VG_NAME"/swap)
    EFI_UUID=$(blkid -s UUID -o value "$EFI")

cat > /mnt/etc/fstab <<EOF
UUID=$EFI_UUID  /boot           vfat        defaults,noatime 0 2

UUID=$BTRFS_UUID    /           btrfs       rw,noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@            0 0

UUID=$BTRFS_UUID    /home       btrfs       rw,noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@home        0 0

UUID=$BTRFS_UUID    /.snapshots btrfs       rw,noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@snapshots   0 0

UUID=$SWAP_UUID     none        swap        defaults                                                                    0 0
EOF
}

main

#!/usr/bin/env bash

set -euo pipefail

VG_NAME="arch"
CRYPT_NAME="cryptroot"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

VERBOSE=false

main() {
    run ping -c1 archlinux.org
    user_options "$@"
    confirm_disk
    set_time
    setup_disk
    setup_btrfs
    setup_swap
    setup_system

    success "Installation concluded!"
    echo "Remove your archiso and reboot your system"
    echo "Recomendations: Setup yay and timeshift/snapper"
}

user_options() {
    get_flags "$@"

    echo -e "\nAvailable disks:"
    lsblk -d -o NAME,SIZE,MODEL | grep -v "loop"
     while true; do
        read -p "Enter disk to install on (e.g., /dev/nvme0n1, /dev/sda): " DISK
        if [[ -b "$DISK" ]]; then
            break
        else
            warning "Disk $DISK does not exist. Please try again."
        fi
    done

    read -rp "Enter swap size (GB): " SWAP_SIZE
    read -rp "Enter timezone [America/Sao_Paulo]: " TIMEZONE
    read -rp "Enter hostname: " HOSTNAME
    read -rp "Enter username: " USERNAME

    if [[ "$DISK" =~ [0-9]$ ]]; then
        EFI="${DISK}p1"
        ROOT="${DISK}p2"
    else
        EFI="${DISK}1"
        ROOT="${DISK}2"
    fi
    info "Disk type detected"

    if grep -q GenuineIntel /proc/cpuinfo; then
        info "INTEL CPU detected"
        UCODE_PACKAGE="intel-ucode"
        UCODE_IMAGE="/intel-ucode.img"
    else
        info "AMD CPU detected"
        UCODE_PACKAGE="amd-ucode"
        UCODE_IMAGE="/amd-ucode.img"
    fi

    info "EFI partition: $EFI"
    info "ROOT partition: $ROOT"

}

select_disk() {
    mapfile -t DISKS < <(lsblk -d -n -o NAME,SIZE,MODEL -e 7,11 | awk '{print "/dev/"$1" ("$2" "$3")"}')


}

get_flags() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose)
                VERBOSE=true
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
        shift
    done
}

info() {
    echo -e "[INFO] $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${RESET} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${RESET} $1"
}

run() {
    if $VERBOSE; then
        "$@"
    else
        "$@" >/dev/null 2>&1
    fi
}

confirm_disk() {
    warning "ALL DATA IN $DISK WILL BE ERASED"
    echo
    lsblk "$DISK"

    read -rp "Type 'ERASE' to confirm: " CONFIRM

    if [[ "$CONFIRM" != "ERASE" ]]; then
        echo "Canceled"
        exit 1
    fi
}

set_time() {
    info "Time set"

    timedatectl set-ntp true
}

setup_disk() {
    info "Setting up disk..."

    wipe_disk
    part_disk
    format_parts

    success "Disk setup complete"
}

wipe_disk() {
    info "$DISK contents wiped"

    run wipefs -af "$DISK"
    run sgdisk --zap-all "$DISK"
}

part_disk() {
    info "Partitioning disk..."

    run parted -s "$DISK" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 1025MiB \
    set 1 esp on \
    mkpart primary 1025MiB 100%

    success "Disk partition setup complete"
}

format_parts() {
    info "Formatting partitions..."
    run mkfs.fat -F32 "$EFI"

    encrypt_root
    setup_lvm

    run mkswap /dev/"$VG_NAME"/swap
    run mkfs.btrfs "/dev/$VG_NAME/root"
}

encrypt_root() {
    info "Encrypting root partition..."

    echo "Enter your LUKS password for $ROOT: "
    read_password "LUKS password"
    local luks_pass="$PASSWORD"
    unset PASSWORD

    info "Formatting LUKS container..."
    printf '%s' "$luks_pass" | cryptsetup luksFormat --batch-mode "$ROOT" -

    info "Opening LUKS container..."
    printf '%s' "$luks_pass" | cryptsetup open "$ROOT" "$CRYPT_NAME" -

    unset luks_pass
    success "LUKS container formatted and opened"
}

setup_lvm() {
    info "Setting up LVM..."

    run pvcreate /dev/mapper/"$CRYPT_NAME"
    run vgcreate "$VG_NAME" /dev/mapper/"$CRYPT_NAME"

    run lvcreate -L "${SWAP_SIZE}G" "$VG_NAME" -n swap
    run lvcreate -l 100%FREE "$VG_NAME" -n root
}

setup_btrfs() {
    info "Setting up btrfs..."

    run mount /dev/"$VG_NAME"/root /mnt
    run mkdir -p /mnt/boot
    run mount "$EFI" /mnt/boot

    run btrfs subvolume create /mnt/@
    run btrfs subvolume create /mnt/@home
    run btrfs subvolume create /mnt/@snapshots

    run umount /mnt/boot
    run umount /mnt

    mount -o rw,noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@ \
    /dev/$VG_NAME/root \
    /mnt

    run mkdir -p /mnt/home
    run mount -o rw,noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@home \
    /dev/$VG_NAME/root \
    /mnt/home

    run mkdir -p /mnt/.snapshots
    run mount -o rw,noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@snapshots \
    /dev/$VG_NAME/root \
    /mnt/.snapshots

    run mkdir -p /mnt/boot
    run mount "$EFI" /mnt/boot

    success "Btrfs setup complete"
}

setup_swap() {
    info "Setting up swap..."

    run swapon /dev/"$VG_NAME"/swap

    success "Swap setup complete"
}

run_with_spinner() {
    local msg="$1"
    shift
    local log_file
    log_file=$(mktemp)

    "$@" > "$log_file" 2>&1 &
    local pid=$!

    local spin='|/-\'
    local i=0

    tput civis 2>/dev/null || true

    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % 4 ))
        printf "\r[INFO] %s... %s" "$msg" "${spin:$i:1}"
        sleep 0.1
    done

    tput cnorm 2>/dev/null || true

    if wait "$pid"; then
        printf "\r${GREEN}[SUCCESS]${RESET} %s complete!      \n" "$msg"
    else
        printf "\r${RED}[ERROR]${RESET} %s failed! See %s for details.\n" "$msg" "$log_file"
        exit 1
    fi
}

read_password() {
    local prompt_label="${1:-password}"
    local pass1 pass2

    while true; do
        read -rs -p "Enter $prompt_label: " pass1
        echo
        read -rs -p "Confirm $prompt_label: " pass2
        echo
        if [[ -z "$pass1" ]]; then
            echo "Password cannot be empty. Please try again."
        elif [[ "$pass1" == "$pass2" ]]; then
            PASSWORD="$pass1"
            break
        else
            echo "Passwords do not match. Please try again."
        fi
    done
}

encrypt_root() {
    info "Encrypting root partition..."

    echo "Set encryption password for $ROOT:"
    read_password "LUKS password"
    local luks_pass="$PASSWORD"
    unset PASSWORD

    info "Formatting LUKS container..."
    printf '%s' "$luks_pass" | cryptsetup luksFormat --batch-mode "$ROOT" -

    info "Opening LUKS container..."
    printf '%s' "$luks_pass" | cryptsetup open "$ROOT" "$CRYPT_NAME" -

    unset luks_pass
    success "LUKS container formatted and opened"
}

setup_system() {
    LUKS_UUID=$(blkid -s UUID -o value "$ROOT")

    run_with_spinner "Installing base system..." pacstrap \
        /mnt \
        base \
        linux \
        linux-lts \
        linux-firmware \
        linux-headers \
        linux-lts-headers \
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

info "Setting up system..."
run arch-chroot /mnt /bin/bash <<EOF
set -e

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

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

mountpoint /boot
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

cat >/boot/loader/entries/arch-lts.conf <<ENTRY
title Arch Linux (LTS)
linux /vmlinuz-linux-lts
initrd $UCODE_IMAGE
initrd /initramfs-linux-lts.img
options rd.luks.name=$LUKS_UUID=$CRYPT_NAME rd.luks.options=discard root=/dev/$VG_NAME/root rootflags=subvol=@ rw
ENTRY

cat >/etc/sudoers.d/wheel <<SUDO
%wheel ALL=(ALL:ALL) ALL
SUDO

chmod 440 /etc/sudoers.d/wheel

systemctl enable NetworkManager

EOF
success "System setup complete"

echo "Set root password:"
read_password "Root password"
local root_pass="$PASSWORD"
unset PASSWORD
echo "root:$root_pass" | arch-chroot /mnt chpasswd

arch-chroot /mnt useradd -m -G wheel "$USERNAME"

echo "Set password for $USERNAME:"
read_password "$USERNAME password"
local user_pass="$PASSWORD"
unset PASSWORD
echo "$USERNAME:$user_pass" | arch-chroot /mnt chpasswd

unset PASS1 PASS2 PASSWORD user_pass root_pass
}

create_fstab() {
    info "Creating fstab..."

    BTRFS_UUID=$(blkid -s UUID -o value /dev/"$VG_NAME"/root)
    SWAP_UUID=$(blkid -s UUID -o value /dev/"$VG_NAME"/swap)
    EFI_UUID=$(blkid -s UUID -o value "$EFI")

run cat > /mnt/etc/fstab <<EOF
UUID=$EFI_UUID  /boot           vfat        defaults,noatime 0 2

UUID=$BTRFS_UUID    /           btrfs       rw,noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@            0 0

UUID=$BTRFS_UUID    /home       btrfs       rw,noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@home        0 0

UUID=$BTRFS_UUID    /.snapshots btrfs       rw,noatime,compress=zstd:3,space_cache=v2,discard=async,subvol=@snapshots   0 0

UUID=$SWAP_UUID     none        swap        defaults                                                                    0 0
EOF

    success "Fstab created"
}

main "$@"

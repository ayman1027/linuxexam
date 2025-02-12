#!/bin/bash

# Configurer le clavier et l'horloge
echo "[+] Configuration du clavier et de l'horloge..."
loadkeys fr-latin1
timedatectl set-ntp true

# Vérification du mode UEFI
if [ ! -d "/sys/firmware/efi" ]; then
    echo "[-] Erreur : Le système n'est pas en mode UEFI !"
    exit 1
fi

# Effacer Partitionnement
echo "[-] Suppression de toutes les partitions existantes sur /dev/sda..."
wipefs --all --force /dev/sda
parted /dev/sda --script mklabel gpt

# Partitionnement en GPT + ESP + LUKS
echo "[+] Création des partitions..."
parted /dev/sda --script mkpart ESP fat32 1MiB 513MiB
parted /dev/sda --script set 1 esp on
parted /dev/sda --script mkpart LUKS ext4 513MiB 100%

# Formater la partition EFI
mkfs.fat -F32 /dev/sda1

# Chiffrer avec LUKS
echo "[+] Chiffrement de /dev/sda2 avec LUKS..."
echo "azerty123" | cryptsetup luksFormat --type luks1 /dev/sda2
echo "azerty123" | cryptsetup open /dev/sda2 cryptroot

# Création des volumes LVM
pvcreate /dev/mapper/cryptroot
vgcreate vg0 /dev/mapper/cryptroot
lvcreate -L 10G -n crypt_volume vg0
lvcreate -L 20G -n virtualbox vg0
lvcreate -L 5G -n shared_folder vg0
lvcreate -l 100%FREE -n root vg0

# Formater et monter les partitions
mkfs.ext4 /dev/vg0/root
mkfs.ext4 /dev/vg0/virtualbox
mkfs.ext4 /dev/vg0/shared_folder

mount /dev/vg0/root /mnt
mkdir -p /mnt/boot
mount /dev/sda1 /mnt/boot

# Installation du système de base
pacstrap /mnt base linux linux-firmware nano sudo lvm2

# Générer le fichier fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot dans le nouveau système et configuration
arch-chroot /mnt <<EOF

# Configuration de la timezone, locale et hostname
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
echo "LANG=fr_FR.UTF-8" > /etc/locale.conf
echo "archlinux" > /etc/hostname

# Ajouter les modules LUKS + LVM à mkinitcpio
sed -i 's/^HOOKS=(.*)/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Installation de GRUB avec support LUKS
echo "[+] Installation de GRUB..."
pacman -Sy --noconfirm grub efibootmgr
echo "GRUB_CMDLINE_LINUX=\"cryptdevice=/dev/sda2:cryptroot root=/dev/mapper/vg0-root\"" > /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# Installer et activer NetworkManager
pacman -Sy --noconfirm networkmanager
systemctl enable NetworkManager
systemctl start NetworkManager

# Création des utilisateurs
useradd -m -G wheel -s /bin/bash user
echo "user:azerty123" | chpasswd
useradd -m -G users -s /bin/bash user2
echo "user2:azerty123" | chpasswd

# Définir le clavier AZERTY pour user et user2
echo "setxkbmap fr" >> /home/user/.bashrc
echo "setxkbmap fr" >> /home/user2/.bashrc
echo "setxkbmap fr" >> /etc/profile

# Ajouter l'utilisateur "user2" au groupe sudoers
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

# 🔹 Installation d'Hyperland et de ses dépendances
pacman -Sy --noconfirm hyprland wayland wayland-utils xorg-xwayland wlroots
pacman -Sy --noconfirm polkit seatd libseat
pacman -Sy --noconfirm xf86-video-vmware mesa vulkan-intel libglvnd
pacman -Sy --noconfirm alacritty firefox neofetch htop git base-devel rofi pavucontrol

# Activer seatd pour Hyperland
systemctl enable seatd
systemctl start seatd

# 🔹 Configuration de Hyperland
mkdir -p /home/user2/.config/hypr
cp /usr/share/hyprland/hyprland.conf /home/user2/.config/hypr/hyprland.conf

echo "exec Hyprland" > /home/user2/.xinitrc
echo "XDG_SESSION_TYPE=wayland" >> /home/user2/.bashrc
echo "dbus-run-session Hyprland" > /home/user2/.config/hypr/start.sh
chmod +x /home/user2/.config/hypr/start.sh

# Ajouter Hyperland au démarrage
echo "exec /home/user2/.config/hypr/start.sh" >> /home/user2/.bash_profile

# Finalisation
echo "[+] Installation terminée ! Redémarre maintenant avec : reboot"
EOF

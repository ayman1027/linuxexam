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

# Ajout des modules LUKS + LVM dans mkinitcpio
echo "[+] Ajout des modules encrypt et lvm2 à mkinitcpio..."
sed -i 's/^HOOKS=(.*)/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Installation de GRUB avec support LUKS
echo "[+] Installation de GRUB..."
pacman -Sy --noconfirm grub efibootmgr

echo "GRUB_CMDLINE_LINUX=\"cryptdevice=/dev/sda2:cryptroot root=/dev/mapper/vg0-root\"" > /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# Installer et activer NetworkManager
echo "[+] Installation et activation de NetworkManager..."
pacman -Sy --noconfirm networkmanager
systemctl enable NetworkManager
systemctl start NetworkManager

# Création des utilisateurs
useradd -m -G wheel -s /bin/bash user
echo "user:azerty123" | chpasswd
useradd -m -G users -s /bin/bash user2
echo "user2:azerty123" | chpasswd

# 🟢 Correction du clavier AZERTY 🟢
echo "KEYMAP=fr-latin1" > /etc/vconsole.conf   # Pour TTY
echo "setxkbmap fr" >> /etc/profile             # Pour session utilisateur
echo "setxkbmap fr" >> /home/user/.bashrc
echo "setxkbmap fr" >> /home/user2/.bashrc

# Changer les permissions pour que chaque user puisse modifier son propre fichier .bashrc
chown user:user /home/user/.bashrc
chown user2:user2 /home/user2/.bashrc

# Ajouter l'utilisateur "user" au groupe sudoers
echo "[+] Ajout de l'utilisateur 'user' dans sudoers..."
usermod -aG wheel user
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

# Ajouter l'utilisateur "user2" au groupe sudoers
echo "[+] Ajout de l'utilisateur 'user2' dans sudoers..."
usermod -aG wheel user2
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

pacman -Sy --noconfirm vim
echo "export EDITOR=vim" >> /home/user2/.bashrc
chown user2:user2 /home/user2/.bashrc

# Ajouter user et user2 aux groupes nécessaires
usermod -aG network,wheel user
usermod -aG network,wheel user2

# Autoriser user et user2 à gérer NetworkManager
echo "[+] Autorisation de gestion du réseau pour user et user2..."
echo "%wheel ALL=(ALL) NOPASSWD: /usr/bin/nmcli" >> /etc/sudoers.d/network
chmod 0440 /etc/sudoers.d/network

echo "[+] Test de la connexion Internet..."
ping -c 4 archlinux.org

# Création du dossier partagé pour user et user2
mkdir /home/user/shared
mkdir /home/user2/shared
chown user:user2 /home/user/shared
chmod 770 /home/user/shared

# Installation des logiciels utiles
pacman -Sy --noconfirm hyprland virtualbox virtualbox-host-dkms linux-headers firefox neofetch htop git base-devel
pacman -Sy --noconfirm neofetch htop btop lsd ranger
pacman -Sy --noconfirm pacman-contrib reflector
pacman -Sy --noconfirm gparted baobab ncdu
pacman -Sy --noconfirm networkmanager nm-connection-editor
pacman -Sy --noconfirm firefox alacritty rofi pavucontrol

# Ajout de GRUB dans les entrées EFI
efibootmgr --create --disk /dev/sda --part 1 --loader /EFI/GRUB/grubx64.efi --label "ArchLinux" --verbose
EOF

echo "[+] Installation terminée ! Redémarre maintenant avec : reboot"


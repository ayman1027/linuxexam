#!/bin/bash

set -e  # Arrête le script en cas d'erreur

# On charge le fichier de config
CONFIG_FILE="./config.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "[-] Oups ! Fichier de configuration '$CONFIG_FILE' introuvable !"
    exit 1
fi

echo "[+] Configuration du clavier et de l'horloge..."
loadkeys $KEYMAP
timedatectl set-ntp true

# Vérification du mode UEFI
if [ ! -d "/sys/firmware/efi" ]; then
    echo "[-] Oups ! Le système n'est pas en mode UEFI !"
    exit 1
fi


# Partitionnement du disque
echo "[-] Suppression des partitions existantes sur $DISK..."
wipefs --all --force $DISK
parted $DISK --script mklabel gpt
parted $DISK --script mkpart ESP fat32 1MiB 513MiB
parted $DISK --script set 1 esp on
parted $DISK --script mkpart LUKS ext4 513MiB 100%

# Chiffrement avec LUKS
echo "[+] Configuration du chiffrement LUKS..."
echo "$MDP" | cryptsetup luksFormat --type luks1 $LUKS_PART
echo "$MDP" | cryptsetup open $LUKS_PART $CRYPT_NAME

# Création des volumes LVM
pvcreate /dev/mapper/$CRYPT_NAME
vgcreate $VG_NAME /dev/mapper/$CRYPT_NAME
lvcreate -L 10G -n secure_volume $VG_NAME
lvcreate -L 20G -n virtualbox_lv $VG_NAME
lvcreate -L 5G -n shared_lv $VG_NAME
lvcreate -L 2G -n swap_lv $VG_NAME
lvcreate -l 100%FREE -n root_lv $VG_NAME

echo "[+] Configuration du volume chiffré manuel..."
echo "$MDP" | cryptsetup luksFormat --type luks1 /dev/$VG_NAME/secure_volume
echo "$MDP" | cryptsetup open /dev/$VG_NAME/secure_volume secure_manual

# erreurs OpenPGP
dd if=/dev/zero of=/dev/mapper/secure_manual bs=1M count=100 status=progress
mkfs.ext4 -F /dev/mapper/secure_manual
cryptsetup close secure_manual
echo "[+] Le volume chiffré de 10G est prêt ! L'utilisateur pourra le monter manuellement."

# Formatage et montage des partitions
mkfs.fat -F32 $ESP_PART
mkfs.ext4 /dev/$VG_NAME/root_lv
mkfs.ext4 /dev/$VG_NAME/virtualbox_lv
mkfs.ext4 /dev/$VG_NAME/shared_lv
mkswap /dev/$VG_NAME/swap_lv

mount /dev/$VG_NAME/root_lv /mnt
mkdir -p /mnt/boot
mount $ESP_PART /mnt/boot
mkdir -p /mnt/shared
mount /dev/$VG_NAME/shared_lv /mnt/shared
swapon /dev/$VG_NAME/swap_lv

# Génération de fstab
mkdir -p /mnt/etc
genfstab -U /mnt >> /mnt/etc/fstab

mkdir -p /mnt/var/lib/virtualbox
mount /dev/$VG_NAME/virtualbox_lv /mnt/var/lib/virtualbox
echo "/dev/mapper/$VG_NAME-virtualbox_lv  /var/lib/virtualbox  ext4  defaults  0 2" >> /mnt/etc/fstab

# Installation du système de base
pacstrap /mnt base linux linux-firmware nano sudo lvm2 networkmanager

cp ./script.sh /mnt/root/script.sh

# Configuration système dans le chroot
arch-chroot /mnt <<EOF
ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime
hwclock --systohc
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
localectl set-keymap $KEYMAP
echo "$HOSTNAME" > /etc/hostname
locale-gen

# Installation des logiciels essentiels
pacman -Sy --noconfirm \
    vim i3-wm i3status i3lock dmenu xorg-xinit xorg-server xterm \
    virtualbox virtualbox-host-dkms linux-headers firefox \
    neofetch htop git base-devel btop lsd ranger pacman-contrib \
    reflector gparted baobab ncdu networkmanager nm-connection-editor \
    alacritty rofi pavucontrol \
    feh network-manager-applet picom dunst

# Ajout de LUKS et LVM à initramfs
sed -i 's/^HOOKS=(\(.*\))/HOOKS=(base udev autodetect modconf block encrypt lvm2 filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Installation et configuration de GRUB
pacman -Sy --noconfirm grub efibootmgr
sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="cryptdevice=$LUKS_PART:$CRYPT_NAME root=/dev/mapper/$VG_NAME-root_lv"|' /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# Activation du réseau
systemctl enable NetworkManager

# Création des utilisateurs
useradd -m -G wheel -s /bin/bash user
echo "user:$MDP" | chpasswd
useradd -m -G users -s /bin/bash user2
echo "user2:$MDP" | chpasswd

# Vérification et correction du home directory
chown -R user:user /home/user
# Correction des permissions
chown -R user:user /home/user/.config
chown user:user /home/user/README_ENCRYPTED_VOLUME
chmod 644 /home/user/README_ENCRYPTED_VOLUME
# Attribution des permissions correctes
chown -R user:user /home/user/.config/alacritty
chmod 644 /home/user/.config/alacritty/alacritty.toml

# Vérification et correction des home directories
for USER in user user2; do
    HOME_DIR="/home/$USER"

    # Vérifier si le home existe, sinon le créer manuellement
    if [ ! -d "$HOME_DIR" ]; then
        echo "[-] Attention : le home de $USER n'existe pas, création en cours..."
        mkdir -p "$HOME_DIR"
        chown $USER:$USER "$HOME_DIR"
        chmod 700 "$HOME_DIR"
    fi
done

# Finalisation de la configuration de i3 et xorg
echo "[+] Configuration de i3 pour tous les utilisateurs..."

for USER in user user2; do
    HOME_DIR="/home/$USER"

    if [ -d "$HOME_DIR" ]; then
        echo "[+] Configuration de i3 pour $USER"

        # Vérifier si le dossier ~/.config existe, sinon le créer
        mkdir -p "$HOME_DIR/.config"

        # Définir DISPLAY pour Xorg
        echo "export DISPLAY=:0" | tee -a /etc/profile
        echo "export DISPLAY=:0" | tee -a /home/$USER/.bashrc
        echo "export DISPLAY=:0" | tee -a /home/$USER/.xprofile

        # Configurer proprement .xinitrc
        echo "exec i3" > "/home/$HOME_DIR/.xinitrc"
        chown $USER:$USER "/home/$HOME_DIR/.xinitrc"
        chmod +x "/home/$HOME_DIR/.xinitrc"

        # Configurer .xprofile si nécessaire
        if [ ! -f "$HOME_DIR/.xprofile" ]; then
            echo "exec startx" > "$HOME_DIR/.xprofile"
            chown $USER:$USER "$HOME_DIR/.xprofile"
            chmod +x "$HOME_DIR/.xprofile"
        fi

        # Correction des permissions pour ~/.config
        chown -R $USER:$USER "$HOME_DIR/.config"
    else
        echo "[-] Le home de $USER n'existe pas encore, configuration ignorée."
    fi
done

echo "[+] Xorg et i3 configurés. Lance 'startx' pour démarrer l'interface graphique !"

# Application des changements
echo "[+] Installation ou mise à jour de i3..."
sudo pacman -S --needed i3-wm --noconfirm

# Vérifier si i3 est lancé avant d'utiliser i3-msg
if [[ -n "$DISPLAY" ]] && (pgrep -x "i3" > /dev/null || pgrep -x "i3-wm" > /dev/null); then
    echo "[+] Rechargement de la configuration i3..."
    i3-msg restart
else
    echo "[-] i3 n'est pas lancé, rechargement impossible."
    echo "    ➜ Lance Xorg avec 'startx' puis exécute 'i3-msg reload'"
fi

pacman -Sy --noconfirm vim
echo "export EDITOR=vim" >> /home/user2/.bashrc
chown user2:user2 /home/user2/.bashrc

# Clavier AZERTY pour les utilisateurs
echo "setxkbmap fr" >> /home/user/.bashrc
echo "setxkbmap fr" >> /home/user2/.bashrc
echo "setxkbmap fr" >> /etc/profile

# Personnalisation du prompt Bash
echo "[+] Personnalisation du prompt Bash..."
cat <<EOT >> /home/user/.bashrc
export PS1="\[\033[1;32m\]\u\[\033[1;37m\]@\[\033[1;33m\]\h\[\033[1;37m\] \w \[\033[0m\]$ "
EOT

# Configuration du dossier partagé
# Suppression des anciens liens symboliques
rm -f /home/user/shared
rm -f /home/user2/shared

# Création des liens symboliques vers /shared/
ln -s /shared /home/user/shared
ln -s /shared /home/user2/shared

# Ajout des permissions
chown -R user:user2 /shared
chmod 770 /shared

# Ajout de sudoers
echo "%wheel ALL=(ALL:ALL) ALL" | EDITOR='tee -a' visudo

# Vérification de la connexion Internet
echo "[+] Test de la connexion Internet..."
ping -c 4 archlinux.org || echo "[-] Attention : La connexion Internet ne fonctionne pas !"

# Correction des locales
echo "[+] Correction des locales en cours..."

# Décommenter les lignes nécessaires dans /etc/locale.gen
sudo sed -i "s/^# *\($LOCALE UTF-8\)/\1/" /etc/locale.gen
sudo sed -i 's/^# *\(fr_FR ISO-8859-1\)/\1/' /etc/locale.gen

# Générer les locales
echo "[+] Génération des locales..."
sudo locale-gen

# Définir la langue par défaut
echo "[+] Configuration des variables d'environnement..."
echo "LANG=$LOCALE" | sudo tee /etc/locale.conf
echo "LC_ALL=$LOCALE" | sudo tee -a /etc/environment
export LANG=$LOCALE
export LC_ALL=$LOCALE
source /etc/locale.conf
source /etc/environment

# Appliquer immédiatement les changements
echo "export LANG=$LOCALE" | sudo tee -a /etc/profile
echo "export LC_ALL=$LOCALE" | sudo tee -a /etc/profile

# Vérification des locales après configuration
echo "[+] Vérification des locales..."
locale

# Vérification que locale-gen a bien généré les locales
if locale -a | grep -q "fr_FR"; then
    echo "[+] Locale générée avec succès"
else
    echo "[-] Erreur : locale-gen n'a pas réussi. Vérifiez /etc/locale.gen"
    exit 1
fi

# Configuration de i3
mkdir -p /home/user/.config/i3
cat <<EOT > /home/user/.config/i3/config
exec --no-startup-id feh --bg-scale /usr/share/pixmaps/archlinux-logo.png &
exec --no-startup-id nm-applet &
exec --no-startup-id picom &
exec --no-startup-id dunst &
exec --no-startup-id setxkbmap fr

# Définit un workspace de base
workspace 1 output primary

# Fermer une fenêtre avec Win+Q
bindsym Mod4+q kill
# Recharger la configuration i3 avec Win+Shift+R
bindsym Mod4+Shift+r reload
# Redémarrer i3 avec Win+Shift+E
bindsym Mod4+Shift+e exec --no-startup-id i3-msg exit
bindsym Mod4+Return exec alacritty
bindsym Mod4+d exec --no-startup-id dmenu_run

# Couleurs pour une esthétique moderne et épurée
client.focused          #1abc9c #2ecc71 #3498db #9b59b6
client.focused_inactive #95a5a6 #34495e #2ecc71 #1abc9c
client.unfocused        #34495e #7f8c8d #34495e #7f8c8d
client.urgent           #e74c3c #e67e22 #e74c3c #e67e22
client.placeholder      #34495e #7f8c8d #34495e #7f8c8d

# Personnalisation de la barre d'état
bar {
    status_command i3status
    position bottom
    colors {
        background #2ecc71
        statusline #ecf0f1
        separator  #3498db
    }
}
EOT

# Configuration de i3status
mkdir -p /home/user/.config/i3status
cat <<EOS > /home/user/.config/i3status/config
general {
    colors = true
    interval = 5
}
order += "disk /"
order += "battery"
order += "cpu_temperature"
order += "memory"
order += "tztime local"

cpu_temperature 0 {
    format = "CPU: %degrees°C"
}

memory {
    format = "RAM: %used/%total"
}

disk "/" {
    format = "Disk: %free"
}

battery 0 {
    format = "Battery: %status %percentage"
}

tztime local {
    format = "%Y-%m-%d %H:%M:%S"
}
EOS

echo "[+] Configuration d'i3status terminée !"

echo "[+] Configuration d'Alacritty..."
# Création du dossier de configuration s'il n'existe pas
mkdir -p /home/user/.config/alacritty
# Création du fichier de configuration en TOML (nouveau format supporté)
cat <<EOY > /home/user/.config/alacritty/alacritty.toml

[colors.primary]
background = "#3E1F00" 
foreground = "#ecf0f1"

[colors.normal]
black   = "#2ecc71"
red     = "#e74c3c"
green   = "#2ecc71"
yellow  = "#f1c40f"
blue    = "#3498db"
magenta = "#9b59b6"
cyan    = "#1abc9c"
white   = "#ecf0f1"

[colors.bright]
black   = "#95a5a6"
red     = "#e74c3c"
green   = "#2ecc71"
yellow  = "#f39c12"
blue    = "#3498db"
magenta = "#9b59b6"
cyan    = "#1abc9c"
white   = "#ffffff"

[font.normal]
family = "FiraCode Nerd Font"
style = "Regular"

[font.bold]
family = "FiraCode Nerd Font"
style = "Bold"

[font.italic]
family = "FiraCode Nerd Font"
style = "Italic"

[cursor]
style = "Block"
unfocused_hollow = true

[window]
padding = { x = 10, y = 10 }
dynamic_padding = true
decorations = "none"
EOY


echo "[+] Vérification et correction de la configuration de Xorg et i3..."

# Création du fichier .Xauthority s'il est manquant
if [ ! -f "$HOME/.Xauthority" ]; then
    echo "[+] Création de ~/.Xauthority..."
    touch "$HOME/.Xauthority"
    chmod 600 "$HOME/.Xauthority"
fi

# Vérification et installation des paquets nécessaires
echo "[+] Vérification de l'installation des paquets requis..."
sudo pacman -Sy --needed xorg xorg-xinit xorg-fonts-misc xorg-xclock xorg-twm xterm i3-wm dmenu feh picom dunst network-manager-applet --noconfirm

# Vérification de la configuration de .xinitrc
if ! grep -q "exec i3" "/home/user/.xinitrc" 2>/dev/null; then
    echo "[+] Configuration de ~/.xinitrc..."
    echo "exec i3" > "/home/user/.xinitrc"
    echo "exec i3" > "/home/user2/.xinitrc"
    chmod +x "/home/user/.xinitrc"
    chmod +x "/home/user2/.xinitrc"
fi

# Vérification du clavier
echo "[+] Configuration du clavier AZERTY (fr)..."
setxkbmap fr

# Correction des polices manquantes
echo "[+] Activation des polices Xorg..."
xset +fp /usr/share/fonts/misc
xset fp rehash

# Vérification de la variable DISPLAY
if [ -z "$DISPLAY" ]; then
    echo "[+] Configuration de DISPLAY..."
    export DISPLAY=:0
fi

echo "[+] Configuration terminée. i3!"

echo "[+] Vérification et exécution du script de logs..."

# Vérification que script.sh est bien présent
if [ -f "/root/script.sh" ]; then
    echo "[+] script.sh trouvé dans /root/, activation des logs..."

    # Donner les permissions d'exécution
    chmod +x /root/script.sh

    # Définir un fichier de log permanent
    LOG_FILE="/var/log/install_log.txt"

    # Rediriger toute la sortie vers le log
    exec > >(tee -a "\$LOG_FILE") 2>&1

    # Exécuter le script de log
    /root/script.sh

    echo "[+] Logs générés et sauvegardés dans /var/log/install_log.txt"
else
    echo "[-] Erreur : script.sh introuvable dans /root/ !"
fi

EOF

echo "[+] Configuration d'Alacritty terminée !"

echo "[+] Installation terminée ! Redémarre maintenant avec : reboot"

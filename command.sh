#!/bin/bash
# Activation de la journalisation des commandes
LOG_FILE="/var/log/install_log.txt"
exec > >(tee -a "$LOG_FILE") 2>&1


# 1️. Afficher les informations sur les disques
lsblk -f

# 2️. Afficher le contenu des fichiers système importants
echo -e "\n=== Contenu de /etc/passwd ===\n"
cat /etc/passwd

echo -e "\n=== Contenu de /etc/group ===\n"
cat /etc/group

echo -e "\n=== Contenu de /etc/fstab ===\n"
cat /etc/fstab

echo -e "\n=== Contenu de /etc/mtab ===\n"
cat /etc/mtab

# 3️. Afficher le hostname de la machine
echo "$HOSTNAME"

# 4️. Afficher la liste des paquets installés
grep -i installed /var/log/pacman.log

echo "cree avec succes dans  : $LOG_FILE"

#!/bin/bash

set -e

# --- Aide ---
if [ -z "$1" ]; then
    echo "Utilisation : $0 nom_du_projet [--writable] [--ssl] [--mvc] [--tout]"
    printf "\033[31mCe script doit être exécuté en tant que root !\033[0m\n"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    printf "\033[31mCe script doit être exécuté en tant que root !\033[0m\n"
    exit 1
fi

# --- Paramètres ---
PROJET="$1"
USER_NAME="${SUDO_USER}"
DOMAINE="${PROJET}.local"
DOSSIER="/srv/web/${PROJET}"
CONF_HTTP="/etc/httpd/conf.d/${PROJET}.conf"
CONF_SSL="/etc/httpd/conf.d/${PROJET}-ssl.conf"
SSL_DIR="/etc/httpd/ssl"
CRT="${SSL_DIR}/${DOMAINE}.crt"
KEY="${SSL_DIR}/${DOMAINE}.key"

WRITABLE=false
ENABLE_SSL=false
MVC=false

# --- Analyse des options ---
for arg in "$@"; do
  case "$arg" in
    --writable) WRITABLE=true ;;
    --ssl) ENABLE_SSL=true ;;
    --mvc) MVC=true;;
    --tout)
        WRITABLE=true
        ENABLE_SSL=true
        MVC=true
        ;;
  esac
done

echo "Création du projet web: $PROJET"

# --- Création du dossier ---
echo "Création du dossier $DOSSIER"
mkdir -p "$DOSSIER"

if $MVC; then
  # Dossier public
  mkdir -p "$DOSSIER/public/"
  mkdir -p "$DOSSIER/public/artsys/"
  mkdir -p "$DOSSIER/public/artsys/css/"
  mkdir -p "$DOSSIER/public/artsys/imgs/"
  mkdir -p "$DOSSIER/public/artsys/js/"

  # Src
  mkdir -p "$DOSSIER/src/"
  mkdir -p "$DOSSIER/src/Configurations/"
  mkdir -p "$DOSSIER/src/Controllers/"
  mkdir -p "$DOSSIER/src/Models/"
  mkdir -p "$DOSSIER/src/Repository/"
  mkdir -p "$DOSSIER/src/Views/"

  tee "$DOSSIER/.htaccess" > /dev/null <<EOF
  <IfModule mod_rewrite.c>
      RewriteEngine On
      RewriteBase /
      RewriteCond %{REQUEST_URI} !^/public/
      RewriteRule ^(.*)$ public/\$1 [L]
  </IfModule>
EOF
fi

chown -R "$USER_NAME:apache" "$DOSSIER"
chmod -R 775 "$DOSSIER"
chmod g+s "$DOSSIER"

# --- SELinux ---
if $WRITABLE; then
  echo "SELinux: autorisation en lecture/écriture"
  chcon -Rt httpd_sys_rw_content_t "$DOSSIER"
else
  echo "SELinux: autorisation en lecture seule"
  chcon -Rt httpd_sys_content_t "$DOSSIER"
fi

# --- Fichier index.php si vide ---
if [ -z "$(ls -A "$DOSSIER")" ]; then
  echo "Création d'un index.php de test"

  if $MVC; then
  cat <<'EOF' | tee "${DOSSIER}/public/index.php" > /dev/null
<?php
echo 'OK';
EOF
  chown "$USER_NAME:apache" "${DOSSIER}/public/index.php"
  chmod 664 "${DOSSIER}/public/index.php"
  else
  cat <<'EOF' | tee "${DOSSIER}/index.php" > /dev/null
<?php
echo 'OK';
EOF
  chown "$USER_NAME:apache" "${DOSSIER}/index.php"
  chmod 664 "${DOSSIER}/index.php"
  fi
fi

# --- Création config HTTP ---
echo "Création de la config Apache HTTP: $CONF_HTTP"
if $ENABLE_SSL; then
  tee "$CONF_HTTP" > /dev/null <<EOF
<VirtualHost *:80>
    ServerName $DOMAINE
    Redirect permanent / https://$DOMAINE/
</VirtualHost>
EOF
else
  tee "$CONF_HTTP" > /dev/null <<EOF
<VirtualHost *:80>
    ServerName $DOMAINE
    DocumentRoot $DOSSIER

    <Directory $DOSSIER>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog logs/${PROJET}-error.log
    CustomLog logs/${PROJET}-access.log combined
</VirtualHost>
EOF
fi

# --- SSL ---
if $ENABLE_SSL; then
  echo "Activation SSL pour $DOMAINE"

  mkdir -p "$SSL_DIR"

  echo "Génération du certificat auto-signé"
  openssl req -x509 -nodes -days 365 \
    -newkey rsa:4096 \
    -keyout "$KEY" \
    -out "$CRT" \
    -subj "/CN=${DOMAINE}"

  echo "Ajout du certificat dans le store de confiance"
  trust anchor "$CRT"

  echo "Création de la config Apache SSL: $CONF_SSL"
  tee "$CONF_SSL" > /dev/null <<EOF
<VirtualHost *:443>
    ServerName $DOMAINE
    DocumentRoot $DOSSIER

    SSLEngine on
    SSLCertificateFile $CRT
    SSLCertificateKeyFile $KEY

    <Directory $DOSSIER>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog logs/${PROJET}-ssl-error.log
    CustomLog logs/${PROJET}-ssl-access.log combined
</VirtualHost>
EOF
fi

# --- /etc/hosts ---
if ! grep -q "$DOMAINE" /etc/hosts; then
  echo "Ajout de $DOMAINE dans /etc/hosts"
  echo "127.0.0.1 $DOMAINE" | tee -a /etc/hosts > /dev/null
fi

# --- Redémarrer Apache ---
echo "Redémarrage du serveur Apache"
systemctl restart httpd

# --- Résumé ---
echo -e "\n\033[32mProjet \"$PROJET\" créé avec succès !\033[0m"
echo "Dossier : $DOSSIER"
echo "Accès HTTP  : http://$DOMAINE"
if $ENABLE_SSL; then
  echo "Accès HTTPS : https://$DOMAINE"
  echo "Redirection HTTP → HTTPS activée"
fi
if $WRITABLE; then
  echo "Apache peut écrire dans le dossier."
fi
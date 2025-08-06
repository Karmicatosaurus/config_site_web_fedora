#!/bin/bash

set -e

if [ -z "$1" ]; then
    echo "Utilisation : $0 nom_du_projet [--writable] [--mvc] [--symfony]"
    echo " --writable : Le dossier de publique peut être entre lecture / écriture"
    echo " --mvc : Créer une structure MVC"
    echo " --symfony : Mets en place le framework symfony"
    echo "Les paramètres --mvc et --symfony ne peuvent être utilisés en même temps."
    printf "\033[31mCe script doit être exécuté en tant que root !\033[0m\n"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    printf "\033[31mCe script doit être exécuté en tant que root !\033[0m\n"
    exit 1
fi

# --- Paramètres ---
PROJET="$1"
UTILISATEUR="$SUDO_USER"
DOMAINE="$PROJET.local"
DOSSIER_RACINE="/srv/web"
DOSSIER_PUB="$DOSSIER_RACINE/$PROJET"
CONF_HTTP="/etc/httpd/conf.d/$PROJET.conf"
CONF_SSL="/etc/httpd/conf.d/$PROJET-ssl.conf"
SSL_DIR="/etc/httpd/ssl"
CRT="$SSL_DIR/$DOMAINE.crt"
KEY="$SSL_DIR/$DOMAINE.key"

WRITABLE=false
MVC=false
SYMFONY=false

# --- Analyse des options ---
for arg in "$@"; do
  case "$arg" in
    --writable) WRITABLE=true ;;
    --mvc) MVC=true ;;
    --symfony) SYMFONY=true ;;
  esac
done

if [[ "$MVC" == true && "$SYMFONY" == true ]]; then
  printf "\033[31mErreur : Impossible d'utiliser --mvc et --symfony en même temps !\033[0m\n"
  exit 1
fi

echo "Création du projet web: $PROJET"

if [[ ! -d "$DOSSIER_RACINE" ]]; then
  echo "Création du dossier $DOSSIER_RACINE"
  mkdir -p "$DOSSIER_RACINE"
  chown -Rf "$UTILISATEUR":apache $DOSSIER_RACINE
fi

if [[ -d "$DOSSIER_PUB" ]]; then
  printf "\033[31mLe dossier %s existe déjà !\033[0m\n" "$DOSSIER_PUB"
  exit 1
else
  mkdir -p "$DOSSIER_PUB"
fi

if $MVC; then
  mkdir -p "$DOSSIER_PUB"/{public/artsys/{css,imgs,js},src/{Configurations,Controllers,Models,Repository,Views}}

  tee "$DOSSIER_PUB/.htaccess" > /dev/null <<EOF
  <IfModule mod_rewrite.c>
      RewriteEngine On
      RewriteBase /
      RewriteCond %{REQUEST_URI} !^/public/
      RewriteRule ^(.*)$ public/\$1 [L]
  </IfModule>
EOF
fi

if $SYMFONY; then
    if [[ ! -f "/usr/local/bin/composer" ]]; then
      echo "Téléchargement de composer ..."  
      php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
      
      HASH_ORIGINE=$(curl -s https://composer.github.io/installer.sig)
      HASH_FICHIER=$(php -r "echo hash_file('SHA384', 'composer-setup.php');")

      if [ "$HASH_ORIGINE" != "$HASH_FICHIER" ]; then
          echo "Le fichier téléchargé n'est pas correct !";
          rm composer-setup.php
          exit 1
      fi

      php composer-setup.php --install_dir=/usr/local/bin --filename=composer
      rm composer-setup.php        
    fi

    sudo -u "$UTILISATEUR" composer create-project --no-interaction --working-dir="$DOSSIER_RACINE" symfony/skeleton "$PROJET"
    sudo -u "$UTILISATEUR" composer --no-interaction --working-dir="$DOSSIER_PUB" require webapp
fi

chown -R "$UTILISATEUR":apache "$DOSSIER_PUB"
chmod g+s "$DOSSIER_PUB"

# --- Config SELinux ---
if $WRITABLE; then
  echo "SELinux: autorisation en lecture/écriture"
  chcon -Rt httpd_sys_rw_content_t "$DOSSIER_PUB"
else
  echo "SELinux: autorisation en lecture seule"
  chcon -Rt httpd_sys_content_t "$DOSSIER_PUB"
fi

# --- Activation SSL ---

echo "Activation SSL pour $DOMAINE"

if [[ ! -d $SSL_DIR ]]; then
  mkdir -p $SSL_DIR
fi

echo "Génération du certificat auto-signé"
openssl req -x509 -nodes -days 365 \
  -newkey rsa:4096 \
  -keyout "$KEY" \
  -out "$CRT" \
  -subj "/CN=$DOMAINE"

echo "Ajout du certificat dans le store de confiance"
trust anchor "$CRT"

echo "Création de la config Apache SSL: $CONF_SSL"

tee "$CONF_HTTP" > /dev/null <<EOF
<VirtualHost *:80>
    ServerName $DOMAINE
    Redirect permanent / https://$DOMAINE/
</VirtualHost>
EOF

if $SYMFONY; then
  DOSSIER_PUB="$DOSSIER_PUB/public"
fi

tee "$CONF_SSL" > /dev/null <<EOF
<VirtualHost *:443>
    ServerName $DOMAINE
    DocumentRoot $DOSSIER_PUB

    SSLEngine on
    SSLCertificateFile $CRT
    SSLCertificateKeyFile $KEY

    <Directory $DOSSIER_PUB>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog logs/$PROJET-ssl-error.log
    CustomLog logs/$PROJET-ssl-access.log combined
</VirtualHost>
EOF

if $SYMFONY; then
  tee "$DOSSIER_PUB"/.htaccess > /dev/null <<EOF
<IfModule mod_rewrite.c>
    RewriteEngine On

    # Ignore les fichiers et dossiers existants
    RewriteCond %{REQUEST_FILENAME} !-f
    RewriteCond %{REQUEST_FILENAME} !-d

    # Redirige tout vers index.php
    RewriteRule ^(.*)$ index.php [QSA,L]
</IfModule>
EOF
fi

# --- Ajoût du domaine dans /etc/hosts ---
if ! grep -q "$DOMAINE" /etc/hosts; then
  echo "Ajout de $DOMAINE dans /etc/hosts"
  echo "127.0.0.1 $DOMAINE" | tee -a /etc/hosts > /dev/null
fi

echo "Redémarrage du serveur Apache"
systemctl restart httpd

echo -e "\n\033[32mProjet \"$PROJET\" créé avec succès !\033[0m"
echo "Dossier : $DOSSIER_PUB"
echo "Accès HTTP  : http://$DOMAINE"
echo "Accès HTTPS : https://$DOMAINE"
echo "Redirection HTTP → HTTPS activée"

if $WRITABLE; then
  echo "Apache peut écrire dans le dossier."
fi

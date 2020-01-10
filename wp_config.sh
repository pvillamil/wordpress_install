#!/bin/bash

# set to fail on error and unset vars
set -eu

mysql_secure_install() {
    # remove anonymous users
    {
        anon_comm="DELETE FROM mysql.user WHERE User='';"
        mysql -u root -e "$anon_comm"
    } || {
        echo "Failed to remove anonymous users from mysql."
        echo "The script will continue but this should be addressed manually"
    }
    # remove remote root login
    {
        rm_remote_comm="DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
        mysql -u root -e "$rm_remote_comm"
    } || {
        echo "Failed to remove remote access for root."
        echo "The script will continue but this should be addressed manually"
    }
    # remove the test db
    {
        rm_tst_db_comm="DROP DATABASE test;DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';"
        mysql -u root -e "$rm_tst_db_comm"
    } || {
        echo "Failed to remove the test db."
        echo "The script will continue but this should be addressed manually"
    }
}

mysql_configure() {
    # $1=db name $2=db username $3=db user pass
    # create wp_db
    local db_name=$1
    local db_user=$2
    local db_user_pass=$3

    # create the db
    {
        create_db_comm="CREATE DATABASE \`$db_name\`;"
        mysql -u root -e "$create_db_comm"
    } || {
        echo "Failed to create the db $db_name"
        exit 1
    }
    # create the wp db user
    {
        create_user_comm="CREATE USER '$db_user'@'localhost' IDENTIFIED WITH mysql_native_password BY '$db_user_pass';"
        mysql -u root -e "$create_user_comm"
    } || {
        echo "Failed to create the db user $db_user"
        exit 1
    }
    # grant wp_db_user permissions to wp db
    {
        grant_priv_comm="GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$db_user'@'localhost';"
        mysql -u root -e "$grant_priv_comm"    
    } || {
        echo "Failed to grant permissions to $db_user for $db_name"
        exit 1
    }
}

php_config() {
    local DB=$1
    local USER=$2
    local PASS=$3
    local CONF_PATH=/var/www/wordpress/wp-config.php
    local SAMPLE=/var/www/wordpress/wp-config-sample.php
    local TMP_F=/tmp/wp-config.php
    local KEY_NAMES=("AUTH_KEY" "SECURE_AUTH_KEY" "LOGGED_IN_KEY" "NONCE_KEY" "AUTH_SALT" "SECURE_AUTH_SALT" "LOGGED_IN_SALT" "NONCE_SALT")
    
    cp "$SAMPLE" "$CONF_PATH"

    local keys=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
    
    for name in "${KEY_NAMES[@]}"
    do
        key_line=$(grep -wn "$name" "$CONF_PATH" | cut -d ":" -f1)
        new_key=$(echo "$keys" | grep -w "$name")
        
        # the large possibility fo special characters in the password makes using awk
        # and sed very difficult so I opted to use head and tail to create a new file
        
        let "start = $key_line - 1"
        let "end = $(wc -l $CONF_PATH | cut -d " " -f 1) - $key_line"
        
        head -n "$start" "$CONF_PATH" > "$TMP_F"
        echo "$new_key" >> "$TMP_F"
        tail -n "$end" "$CONF_PATH" >> "$TMP_F"
        
        mv "$TMP_F" "$CONF_PATH"
    done

    sed -i 's/database_name_here/'"$DB"'/g' "$CONF_PATH"
    sed -i 's/username_here/'"$USER"'/g' "$CONF_PATH"
    sed -i 's/password_here/'"$PASS"'/g' "$CONF_PATH"

    if [[ ! $(grep "FS_METHOD" $CONF_PATH) ]]
    then
        echo "define('FS_METHOD', 'direct');" >> $CONF_PATH
    fi
}

install_pkg() {
    local PKG=$1

    if ! dpkg -s "$PKG" &> /dev/null
    then
        {
            echo "Installing $PKG..."
            apt-get install -y "$PKG" &> /dev/null
        } || {
            echo "Failed to install $PKG"
            exit 1
        }
    else
        echo "$PKG already installed."
    fi
}

# MAIN

WWW_ROOT=/var/www/
WP_ROOT="${WWW_ROOT}wordpress/"
DBUSER=wpUser

# get domain name
echo "Please enter the domain name: "
read domain

### install packages
echo -e "\nINSTALING PACKAGES"
# update package manifest
echo -e "Updating package manifest..."
apt-get update &> /dev/null

PACKAGES=("php" "php-curl" "php-gd" "php-intl" "php-mbstring" "php-soap"
    "php-xml" "php-xmlrpc" "php7.3-fpm" "php-zip" "php-mysql" "mysql-server"
    "nginx")

for pkg in "${PACKAGES[@]}"
do
    install_pkg "$pkg" 
done

# insert blank line in output for readability
echo ""

### db setup
echo -e "CONFIGURING MYSQL"
# start service
{ 
    echo "Starting mysql..."
    systemctl start mysql &> /dev/null
} || {
    echo "Failed to start the mysql service"
    exit 1
}
# enable the mysql service
{
    echo -e "Enabling mysql...\n"
    systemctl enable mysql &> /dev/null
} || {
    echo "Failed to start the mysql service."
    echo "The script will continue but this should be addressed manually."
}

## mysql secure install
DBNAME="${domain}_db"
# create password for db user
DBUSERPASS=$(date | md5sum | awk '{print $1}')
## configure the db
echo "Creating $DBUSER and $DBNAME..."
mysql_configure "$DBNAME" "$DBUSER" "$DBUSERPASS"

### add entry to /etc/hosts
echo -e "Adding entry to /etc/hosts\n"
# use touch to make sure /etc/hosts exists
touch /etc/hosts
# create line
dom_line="127.0.0.1 $domain"
# delete any existing references to the domain
sed -i '/'^"$domain"'/d' /etc/hosts
# add the domain line
echo "$dom_line" >> /etc/hosts

## configuring nginx
echo -e "CONFIGURING NGINX\n"

# copy default wp nginx.conf and add the server_name
{
    echo -e "Copying nginx config..."
    sed 's/insert_server_name/'"$domain"'/g' files/wordpress > /etc/nginx/sites-available/wordpress
    ln -s /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/wordpress 
} || {
    echo "Failed to cp the nginx conf"
    exit 1
}

# unlink default page
{
    echo -e "Disabling the default site...\n"
    unlink /etc/nginx/sites-enabled/default
} || {
    echo "Failed to disable the default site."
    exit 1
}

## install wordpress
echo -e "INSTALLING WORDPRESS\n"

# download latest wordpress
{
    echo -e "Extracting wordpress...\n"
    cd /tmp
    curl -LO http://wordpress.org/latest.tar.gz &> /dev/null
} || { 
    echo "Failed to download the latest wordpress"
    exit 1
}

# extract latest
{
    if [[ ! -d "${WWW_ROOT}wordpress" ]]
    then    
        tar -C ${WWW_ROOT} -xvzf latest.tar.gz &> /dev/null
    else
        echo "${WWW_ROOT}wordpress already exists."
    fi
} || {
    echo "Failed to extract the wordpress archive."
    exit 1
}

## create wp-config.php
echo -e "Creating php config...\n"
php_config "$DBNAME" "$DBUSER" "$DBUSERPASS"

## make sure no apache instances are running
if [[ $(systemctl is-active --quiet apache2) -eq 0 ]]
then
    {
        echo -e "Apache2 is running.\nStopping...\n"
        systemctl stop apache2 &> /dev/null &&\
        systemctl disable apache2 &> /dev/null
    } || {
        echo -e "Apache2 is running and failed to stop or disable.\nPlease check."
    }
fi

# set ownership on WP_ROOT
echo -e "Setting ownership of $WP_ROOT to www-data:www-data...\n"
chown -R www-data:www-data "$WP_ROOT"

## start php-fpm
{
    echo -e "Starting php-fpm...\n"
    systemctl start php7.3-fpm &> /dev/null &&\
    systemctl enable php7.3-fpm &> /dev/null
} || {
    echo "Failed to satrt php-fpm."
    exit 1
}

## start nginx service
{ 
    systemctl restart nginx &> /dev/null
} || {
    echo "Failed to start the nginx service"
    exit 1
}
# enable the nginx service
{
    systemctl enable nginx &> /dev/null
} || {
    echo "Failed to enable the nginx service."
    echo "The script will continue but this should be addressed manually."
}

echo -e "The script completed successfully."
echo -e "\nPLEASE NOTE!\nThe pw for the db user $DBUSER is: $DBUSERPASS\n"
echo "Please complete the installation at $domain."

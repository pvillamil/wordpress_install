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
        create_user_comm="CREATE USER '$db_user'@'localhost' IDENTIFIED BY '$db_user_pass';"
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

    if [[ ! $(dpkg -l "$PKG") ]]; then
        {
            echo "Installing $PKG"
            apt-get install -y "$PKG" 2> /dev/null
        } || {
            echo "Failed to install $PKG"
            exit 1
        }
    fi
}

WWW_ROOT=/var/www/
WP_ROOT="${WWW_ROOT}wordpress/"
DBUSER=wpUser

PACKAGES=("php" "php-curl" "php-gd" "php-xml" "php-xmlrpc" "php7.3-fpm" "php-mysql" "mysql-server"
    "nginx")

for pkg in "${PACKAGES[@]}"
do
    install_pkg "$pkg" 
done

# check if php is installed and install if it is not
#if [[ ! $(dpkg -l php) ]]; then
#    {
#        apt-get install -y php php-curl php-gd php-intl php-mbstring php-soap \
#        php-xml php-xmlrpc php-zip php-fpm php-mysql
#    } || {
#        echo "Failed to install PHP"
#        exit 1
#    }
#fi
#
## check if mysql is installed and install if it is not
#if [[ ! $(dpkg -l mysql-server) ]]; then
#    {
#        apt-get install -y mysql-server
#    } || {
#        echo "Failed to install mysql"
#        exit 1
#    }
#fi
#
## check if nginx is installed and install if it is not
#if [[ ! $(dpkg -l nginx) ]]; then
#    {
#        apt-get install -y nginx
#    } || {
#        echo "Failed to install nginx"
#        exit 1
#    }
#fi

# get domain name
echo "Please enter the domain name: "
read domain

### add entry to /etc/hosts
# use touch to make sure /etc/hosts exists
touch /etc/hosts
# create line
dom_line="$domain   localhost"
# delete any existing references to the domain
sed -i '/'^"$domain"'/d' /etc/hosts
# add the domain line
echo "$dom_line" >> /etc/hosts

# copy default wp nginx.conf
{
    cp files/wordpress.conf /etc/nginx/sites-available/
    ln -s /etc/nginx/sites-available/wordpress.conf /etc/nginx/sites-enabled/wordpress.conf 
} || {
    echo "Failed to cp the nginx conf"
    exit 1
}

# unlink default page
{
    unlink /etc/nginx/sites-enabled/default.conf
} || {
    echo "Failed to disable the default site."
    exit 1
}

# set the domain in the conf
sed -i 's/domain.tld/'"$domain"'/g' /etc/nginx/sites-available/wordpress.conf

# download latest wordpress
{ 
    cd /tmp
    curl -LO http://wordpress.org/latest.tar.gz
} || { 
    echo "Failed to download the latest wordpress"
    exit 1
}

# extract latest
{
    if [[ ! -d "${WWW_ROOT}wordpress" ]]
    then    
        tar -C ${WWW_ROOT} -xvzf latest.tar.gz
    else
        echo "${WWW_ROOT}wordpress already exists."
    fi
} || {
    echo "Failed to extract the wordpress archive."
    exit 1
}

### db setup
#echo "PLEASE NOTE!\nThe DB root password is: $DBPASS"
# start service
{ 
    systemctl start mysql
} || {
    echo "Failed to start the mysql service"
    exit 1
}
# enable the mysql service
{
    systemctl enable mysql
} || {
    echo "Failed to start the mysql service."
    echo "The script will continue but this should be addressed manually."
}
## mysql secure install
DBNAME="${domain}_db"
# create password for db user
DBUSERPASS=$(date | md5sum | awk '{print $1}')
echo -e "PLEASE NOTE!\n The pw for the db user wp_db_user is: $DBUSERPASS"
## configure the db
mysql_configure "$DBNAME" "$DBUSER" "$DBUSERPASS"

## create wp-config.php
php_config "$DBNAME" "$DBUSER" "$DBUSERPASS"

## make sure no apache instances are running
systemctl stop apache2
systemctl disable apache2

## start nginx service
{ 
    systemctl start nginx
} || {
    echo "Failed to start the nginx service"
    exit 1
}
# enable the mysql service
{
    systemctl enable nginx
} || {
    echo "Failed to enable the nginx service."
    echo "The script will continue but this should be addressed manually."
}

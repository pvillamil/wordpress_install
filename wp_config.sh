#!/bin/bash

# set to fail on error and unset vars
set -eu

mysql_secure_install() {
    # perform mysql secure install steps
    local root_pass=$1

    # set root password to random password
    {
        pw_comm="UPDATE mysql.user SET Password=PASSWORD($root_pass) WHERE User='root';FLUSH PRIVILEGES;"
        mysql -u root -e "$pw_comm"
    } || {
        echo "Failed to update the mysql root password."
        exit 1
    }
    # remove anonymous users
    {
        anon_comm="DELETE FROM mysql.user WHERE User='';"
        mysql -u root -p "$DBPASS" -e "$anon_comm"
    } || {
        echo "Failed to remove anonymous users from mysql."
        echo "The script will continue but this should be addressed manually"
    }
    # remove remote root login
    {
        rm_remote_comm="DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
        mysql -u root -p "$root_pass" -e "$rm_remote_comm"
    } || {
        echo "Failed to remove remote access for root."
        echo "The script will continue but this should be addressed manually"
    }
    # remove the test db
    {
        rm_tst_db_comm="DROP DATABASE test;DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';"
        mysql -u root -p "$root_pass" -e "$rm_tst_db_comm"
    } || {
        echo "Failed to remove the test db."
        echo "The script will continue but this should be addressed manually"
    }
}

mysql_configure() {
    # $1=db name $2 =db root pass $3=db username $4=db user pass
    # create wp_db
    local db_name=$1
    local root_pass=$2
    local db_user=$3
    local db_user_pass=$4

    # create the db
    {
        create_db_comm="CREATE DATABASE $db_name;"
    } || {
        echo "Failed to create the db $db_name"
        exit 1
    }
    # create the wp db user
    {
        create_user_comm="CREATE USER $db_user@'localhost' IDENTIFIED BY $db_user_pass;"
        mysql -u root -p "$root_pass" -e "$create_user_comm"
    } || {
        echo "Failed to create the db user $db_user"
        exit 1
    }
    # grant wp_db_user permissions to wp db
    {
        grant_priv_comm="GRANT ALL PRIVILEGES ON $db_name TO $db_user@'localhost' INDENTIFIED BY $db_user_pass;"
        mysql -u root -p "DBPASS" -e "$grant_priv_comm"    
    } || {
        echo "Failed to grant permissions to wp_db_user for $dbname"
        exit 1
    }
}

# check if php is installed and install if it is not
if [[ ! $(dpkg -l php) ]]; then
    {
        apt-get install -y php
    } || {
        echo "Failed to install PHP"
        exit 1
    }
fi

# check if mysql is installed and install if it is not
if [[ ! $(dpkg -l mysql-server) ]]; then
    {
        apt-get install -y mysql-server
    } || {
        echo "Failed to install mysql"
        exit 1
    }
fi

# check if nginx is installed and install if it is not
if [[ ! $(dpkg -l nginx) ]]; then
    {
        apt-get install -y nginx
    } || {
        echo "Failed to install nginx"
        exit 1
    }
fi

# get domain name
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
    cp files/nginx.conf /etc/nginx/nginx.conf
} || {
    echo "Failed to cp the nginx conf"
    exit 1
}

# set the domain in the conf
sed -i 's/domain.tld/'"$domain"'/g' /etc/hosts

# download latest wordpress
{ 
    curl -LO http://wordpress.org/latest.zip 
} || { 
    echo "Failed to download the latest wordpress"
    exit 1
}

# unzip latest
{
    unzip latest.zip -d /var/www/wordpress
}

### db setup
# generate random root db password
# there are more random options but this is probably good enough for this use
# case
DBPASS=$(date | md5sum | awk '{print $1}')
echo "PLEASE NOTE!\nThe DB root password is: $DBPASS"
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
# mysql secure install
DBNAME="$domain_db"
mysql_secure_install "$DBPASS"
# create password for db user
DBUSERPASS=$(date | md5sum | awk '{print $1}')
echo "PLEASE NOTE!\n The pw for the db user wp_db_user is: $DBUSERPASS"
# configure the db
mysql_configure "$DBNAME" "$DBPASS" "wp_db_user" "$DBUSERPASS"

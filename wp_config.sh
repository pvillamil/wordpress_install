#!/bin/bash

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

# add entry to /etc/hosts
# use touch to make sure /etc/hosts exists
touch /etc/hosts
# create line
dom_line = "$domain   localhost"
# delete any existing references to the domain
sed -i '/'^"$domain"'/d' /etc/hosts
# add the domain line
echo "$dom_line" >> /etc/hosts

# create nginx conf
{
    cp nginx.conf /etc/nginx/nginx.conf
} || {
    echo "Failed to cp the nginx conf"
    exit 1
}

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

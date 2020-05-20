#!/bin/bash
#
# <UDF name="NODE_HOSTNAME" label="Short hostname, e.g. 'web01-dev-syd'" />
# <UDF name="NODE_FQDN" label="Host FQDN, e.g. 'web01-dev-syd.linode.linacreative.com'" />
# <UDF name="NODE_TIMEZONE" label="System timezone" default="Australia/Sydney" />
# <UDF name="NODE_SERVICES" label="Services to install and configure" manyof="apache+php,mysql,fail2ban" default="apache+php,mysql,fail2ban" />
# <UDF name="HOST_DOMAIN" label="Initial hosting domain (if needed), e.g. 'clientname.com.au'" default="" />
# <UDF name="HOST_ACCOUNT" label="Manual override for initial account name" default="" />
# <UDF name="ADMIN_USERS" label="Admin users to create (space delimited)" default="linac" />
# <UDF name="ADMIN_EMAIL" label="Forwarding address for system email" default="tech@linacreative.com" />
# <UDF name="MYSQL_USERNAME" label="MySQL admin username" default="dbadmin" />
# <UDF name="MYSQL_PASSWORD" label="MySQL password (admin user won't be created if left blank)" default="" />
# <UDF name="SMTP_RELAY" label="SMTP relay, e.g. '[smtp-syd.linode.linacreative.com]'" default="" />
# <UDF name="AUTO_REBOOT" label="Reboot automatically after unattended upgrades?" oneof="Y,N" default="Y" />
# <UDF name="AUTO_REBOOT_TIME" label="Preferred automatic reboot time" oneof="02:00,03:00,04:00,05:00,06:00,07:00,08:00,09:00,10:00,11:00,12:00,13:00,14:00,15:00,16:00,17:00,18:00,19:00,20:00,21:00,22:00,23:00,00:00,01:00,now" default="02:00" />
# <UDF name="PATH_PREFIX" label="Prefix for config files generated by this script" default="lk-" />
# <UDF name="CALL_HOME_MX" label="Call home MX" default="smtp.linacreative.com" />
#
# To test locally using a MySQL password with special characters:
#
#export NODE_HOSTNAME="web01-dev-syd"
#export NODE_FQDN="web01-dev-syd.linode.linacreative.com"
#export NODE_TIMEZONE="Australia/Sydney"
#export NODE_SERVICES="apache+php,mysql,fail2ban"
#export HOST_DOMAIN="lk-test.localhost"
#export HOST_ACCOUNT=
#export ADMIN_USERS="linac"
#export ADMIN_EMAIL="tech@linacreative.com"
#export MYSQL_USERNAME="dbadmin"
#export MYSQL_PASSWORD=$'6@Z!Xg\'_,~&%(]A!)`Cwc>+\'Z:5b$:\\2'
#export SMTP_RELAY="[smtp-syd.linode.linacreative.com]"
#export AUTO_REBOOT="Y"
#export AUTO_REBOOT_TIME="02:00"
#export PATH_PREFIX="lk-"
#export CALL_HOME_MX="smtp.linacreative.com"
#
# To source the above, run:
#
# . <(grep '^#export ' hosting.sh | sed 's/^#//') && echo -e "MySQL admin user credentials:\n  user $MYSQL_USERNAME\n  pass $MYSQL_PASSWORD"
#

function is_installed() {
    local STATUS
    STATUS="$(dpkg-query -f '${db:Status-Status}' -W "$1" 2>/dev/null)" &&
        [ "$STATUS" = "installed" ]
}

function now() {
    date +'%Y-%m-%d %H:%M:%S'
}

function log() {
    {
        printf '%s %s\n' "$(now)" "$1"
        shift
        [ "$#" -eq "0" ] ||
            printf '  %s\n' "${@//$'\n'/$'\n  '}" ""
    } | tee -a "/var/log/${PATH_PREFIX}install.log"
}

function log_file() {
    log "<<<< $1" \
        "$(cat "$1")" \
        ">>>>"
}

function nc() (
    exec 3<>"/dev/tcp/$1/$2"
    cat >&3
    cat <&3
    exec 3>&-
)

function keep_trying() {
    local ATTEMPT=1 MAX_ATTEMPTS="${MAX_ATTEMPTS:-10}" WAIT=5 LAST_WAIT=3 NEW_WAIT EXIT_STATUS
    if ! "$@"; then
        while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
            [ "${NO_LOG:-0}" -eq "1" ] || log "Command failed:" "$*"
            if [ "${NO_WAIT:-0}" -ne "1" ]; then
                [ "${NO_LOG:-0}" -eq "1" ] || log "Waiting $WAIT seconds"
                sleep "$WAIT"
                ((NEW_WAIT = WAIT + LAST_WAIT))
                LAST_WAIT="$WAIT"
                WAIT="$NEW_WAIT"
            fi
            [ "${NO_LOG:-0}" -eq "1" ] || log "Retrying (attempt $((++ATTEMPT))/$MAX_ATTEMPTS)"
            if "$@"; then
                return
            else
                EXIT_STATUS="$?"
            fi
        done
        return "$EXIT_STATUS"
    fi
}

function exit_trap() {
    local EXIT_STATUS="$?"
    # restore stdout and stderr
    exec 1>&6 2>&7 6>&- 7>&-
    if [ -n "${CALL_HOME_MX:-}" ]; then
        nc "$CALL_HOME_MX" 25 <<EOF || true
HELO $NODE_FQDN
MAIL FROM:<root@$NODE_FQDN>
RCPT TO:<$ADMIN_EMAIL>
DATA
From: root@$NODE_FQDN
To: $ADMIN_EMAIL
Date: $(date -R)
Subject: Deployment report for Linode $NODE_FQDN

Exit status: $EXIT_STATUS

Log files:

<<</var/log/${PATH_PREFIX}install.log
$(cat "/var/log/${PATH_PREFIX}install.log" 2>&1 || :)
>>>

<<</var/log/${PATH_PREFIX}install.out
$(cat "/var/log/${PATH_PREFIX}install.out" 2>&1 || :)
>>>

.
QUIT
EOF
    fi
}

set -euo pipefail
shopt -s nullglob

trap 'exit_trap' EXIT

PATH_PREFIX="${PATH_PREFIX:-stackscript-}"
HOST_DOMAIN="${HOST_DOMAIN#www.}"
HOST_ACCOUNT="${HOST_ACCOUNT:-${HOST_DOMAIN%%.*}}"
exec 6>&1 7>&2 # save stdout and stderr to restore later
exec > >(tee -a "/var/log/${PATH_PREFIX}install.out") 2>&1
if [ "${SCRIPT_DEBUG:-N}" = "Y" ]; then
    set -x
else
    export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true
fi

if [ ! -s "/root/.ssh/authorized_keys" ]; then
    log "==== $(basename "$0"): at least one SSH key must be added to Linodes deployed with this StackScript"
    exit 1
fi

. /etc/lsb-release

case "$DISTRIB_RELEASE" in
*)
    # "-yn" disables add-apt-repository's automatic package cache update
    ADD_APT_REPOSITORY_ARGS=(-yn)
    ;;&

16.04)
    # in 16.04, the package cache isn't automatically updated by default
    ADD_APT_REPOSITORY_ARGS=(-y)
    ;;
esac

log "==== $(basename "$0"): preparing system"
log "Environment:" \
    "$(printenv)"

IPV4_ADDRESS="$(
    ip a |
        awk '/inet / { print $2 }' |
        grep -Ev '^(127|10|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.'
)" || IPV4_ADDRESS=
log "Public IPv4 address: ${IPV4_ADDRESS:-not assigned to an interface}"
IPV6_ADDRESS="$(
    ip a |
        awk '/inet6 / { print $2 }' |
        grep -Eiv '^(::1/128|fe80::|f[cd])' |
        sed -E 's/\/[0-9]+$//'
)" || IPV6_ADDRESS=
log "Public IPv6 address: ${IPV6_ADDRESS:-not assigned to an interface}"

log "Setting \"Storage=persistent\" in /etc/systemd/journald.conf"
if [ -f "/etc/systemd/journald.conf" ] &&
    grep -Eq '^#?Storage=' "/etc/systemd/journald.conf"; then
    sed -Ei.orig 's/^#?Storage=.*$/Storage=persistent/' "/etc/systemd/journald.conf"
else
    [ ! -e "/etc/systemd/journald.conf" ] ||
        mv "/etc/systemd/journald.conf" "/etc/systemd/journald.conf.orig"
    cat <<EOF >"/etc/systemd/journald.conf"
[Journal]
Storage=persistent
EOF
fi

log "Restarting systemd-journald.service to activate persistent log storage"
systemctl restart systemd-journald.service

log "Setting system hostname to '$NODE_HOSTNAME'"
hostnamectl set-hostname "$NODE_HOSTNAME"

log "Adding entries for '$NODE_HOSTNAME' and '$NODE_FQDN' to /etc/hosts"
printf '%s\n' "" \
    "# Added by $(basename "$0") at $(now)" \
    "127.0.1.1 $NODE_HOSTNAME" \
    ${IPV4_ADDRESS:+"$IPV4_ADDRESS $NODE_FQDN"} \
    ${IPV6_ADDRESS:+"$IPV6_ADDRESS $NODE_FQDN"} >>/etc/hosts

for USERNAME in $ADMIN_USERS; do
    log "Creating superuser '$USERNAME'"
    useradd --create-home --groups adm,sudo --shell /bin/bash "$USERNAME"
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/nopasswd-$USERNAME"
    [ ! -e "/root/.ssh" ] || {
        log "Moving /root/.ssh to /home/$USERNAME/.ssh"
        mv "/root/.ssh" "/home/$USERNAME/" &&
            chown -R "$USERNAME": "/home/$USERNAME/.ssh"
    }
done

log "Disabling login as root"
passwd -l root

log "Configuring unattended APT upgrades and disabling optional dependencies"
APT_CONF_FILE="/etc/apt/apt.conf.d/90${PATH_PREFIX}defaults"
[ "$AUTO_REBOOT" = "Y" ] || REBOOT_COMMENT="//"
cat <<EOF >"$APT_CONF_FILE"
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Mail "root";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
${REBOOT_COMMENT:-}Unattended-Upgrade::Automatic-Reboot "true";
${REBOOT_COMMENT:-}Unattended-Upgrade::Automatic-Reboot-Time "$AUTO_REBOOT_TIME";
EOF
log_file "$APT_CONF_FILE"

# see `man invoke-rc.d` for more information
log "Disabling automatic \"systemctl start\" when new services are installed"
cat <<EOF >"/usr/sbin/policy-rc.d"
#!/bin/sh
# Created by $(basename "$0") at $(now)
exit 101
EOF
chmod a+x "/usr/sbin/policy-rc.d"
log_file "/usr/sbin/policy-rc.d"

log "Upgrading pre-installed packages"
keep_trying apt-get -q update
keep_trying apt-get -yq dist-upgrade

# bare necessities
PACKAGES=(
    #
    atop
    ntp

    #
    apt-utils
    bash-completion
    byobu
    coreutils
    cron
    curl
    htop
    info
    iptables
    iputils-ping
    iputils-tracepath
    less
    logrotate
    lsof
    man-db
    manpages
    nano
    psmisc
    pv
    rsync
    tcpdump
    telnet
    time
    tzdata
    vim
    wget

    #
    apt-listchanges
    unattended-upgrades
)

# if service installations have been requested, add-apt-repository
# will need to be available
[ -z "$NODE_SERVICES" ] ||
    PACKAGES+=(software-properties-common)

# pre-seed debconf
debconf-set-selections <<EOF
postfix	postfix/main_mailer_type	select	Internet Site
postfix	postfix/mailname	string	$NODE_FQDN
postfix	postfix/relayhost	string	$SMTP_RELAY
postfix	postfix/root_address	string	$ADMIN_EMAIL
EOF

log "Installing APT packages:" "${PACKAGES[*]}"
keep_trying apt-get -yq install "${PACKAGES[@]}"

# set timezone
log "Setting system timezone to '$NODE_TIMEZONE'"
timedatectl set-timezone "$NODE_TIMEZONE"

log "Starting atop.service"
systemctl start atop.service

log "Starting ntp.service"
systemctl start ntp.service

case ",$NODE_SERVICES," in
,,) ;;

*)
    REPOS=(
        universe
        ppa:certbot/certbot
    )

    PACKAGES=(
        #
        postfix
        certbot

        #
        git
        jq
    )
    ;;&

*,apache+php,*)
    PACKAGES+=(
        #
        apache2
        php-fpm
        python3-certbot-apache

        #
        php-apcu
        php-apcu-bc
        php-bcmath
        php-cli
        php-curl
        php-gd
        php-gettext
        php-imagick
        php-imap
        php-intl
        php-json
        php-ldap
        # php-libsodium
        php-mbstring
        php-memcache
        php-memcached
        php-mysql
        # php-net-socket
        php-opcache
        php-pear
        php-pspell
        php-readline
        # php-snmp
        php-soap
        php-sqlite3
        php-xml
        php-xmlrpc
        php-yaml
        php-zip
    )
    ;;&

*,mysql,*)
    PACKAGES+=(
        mariadb-server
    )
    ;;&

*,fail2ban,*)
    PACKAGES+=(
        fail2ban
    )
    ;;&

*)
    log "Adding APT repositories:" "${REPOS[@]}"
    for REPO in "${REPOS[@]}"; do
        keep_trying add-apt-repository "${ADD_APT_REPOSITORY_ARGS[@]}" "$REPO"
    done

    log "Installing APT packages:" "${PACKAGES[*]}"
    keep_trying apt-get -q update
    keep_trying apt-get -yq install "${PACKAGES[@]}"

    if [ -n "$HOST_DOMAIN" ]; then
        log "Creating user account '$HOST_ACCOUNT'"
        useradd --no-create-home --home-dir "/srv/www/$HOST_ACCOUNT" --shell /usr/sbin/nologin
        mkdir -p "/srv/www/$HOST_ACCOUNT"/{public_html,log}
        chown -Rc "$HOST_ACCOUNT:" "/srv/www/$HOST_ACCOUNT"
        if is_installed apache2; then
            log "Adding user 'www-data' to group '$(id -gn "$HOST_ACCOUNT")'"
            usermod --append --groups "$(id -gn "$HOST_ACCOUNT")" "www-data"
        fi
    fi
    ;;

esac

if is_installed fail2ban; then
    log "Starting fail2ban.service"
    systemctl start fail2ban.service
fi

if is_installed postfix; then
    log "Binding postfix to the loopback interface"
    /usr/sbin/postconf -e "inet_interfaces = loopback-only"
    log_file "/etc/postfix/main.cf"
    log_file "/etc/aliases"
    log "Starting postfix.service"
    systemctl start postfix.service
fi

# shellcheck disable=SC2086,SC2207
if is_installed apache2; then
    APACHE_MODS=(
        # Ubuntu 18.04 defaults
        access_compat
        alias
        auth_basic
        authn_core
        authn_file
        authz_core
        authz_host
        authz_user
        autoindex
        deflate
        dir
        env
        filter
        mime
        mpm_event
        negotiation
        reqtimeout
        setenvif
        status

        # extras
        headers
        info
        macro
        proxy
        proxy_fcgi
        rewrite
        socache_shmcb # dependency of "ssl"
        ssl
    )
    APACHE_MODS_ENABLED="$(a2query -m | grep -Eo '^[^ ]+' | sort | uniq)"
    APACHE_DISABLE_MODS=($(comm -13 <(printf '%s\n' "${APACHE_MODS[@]}" | sort | uniq) <(echo "$APACHE_MODS_ENABLED")))
    APACHE_ENABLE_MODS=($(comm -23 <(printf '%s\n' "${APACHE_MODS[@]}" | sort | uniq) <(echo "$APACHE_MODS_ENABLED")))
    [ "${#APACHE_DISABLE_MODS[@]}" -eq "0" ] || {
        log "Disabling with a2dismod:" "${APACHE_DISABLE_MODS[*]}"
        a2dismod --force "${APACHE_DISABLE_MODS[@]}"
    }
    [ "${#APACHE_ENABLE_MODS[@]}" -eq "0" ] || {
        log "Enabling with a2enmod:" "${APACHE_ENABLE_MODS[*]}"
        a2enmod --force "${APACHE_ENABLE_MODS[@]}"
    }

    log "Configuring Apache HTTPD to serve PHP-FPM virtual hosts"
    cat <<EOF >"/etc/apache2/sites-available/${PATH_PREFIX}default.conf"
<Directory /srv/www/*/public_html>
    Options SymLinksIfOwnerMatch
    AllowOverride All Options=Indexes,MultiViews,SymLinksIfOwnerMatch
    Require all granted
</Directory>
<IfModule mod_status.c>
    ExtendedStatus On
</IfModule>
<VirtualHost *:80>
    ServerAdmin $ADMIN_EMAIL
    DocumentRoot /var/www/html
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
    <IfModule mod_status.c>
        <Location /httpd-status>
            SetHandler server-status
            Require ip 127
        </Location>
    </IfModule>
    <IfModule mod_info.c>
        <Location /httpd-info>
            SetHandler server-info
            Require ip 127
        </Location>
    </IfModule>
</VirtualHost>
<IfModule mod_macro.c>
    <Macro PhpFpmVirtualHostCommon72 %sitename%>
        ServerAdmin $ADMIN_EMAIL
        DocumentRoot /srv/www/%sitename%/public_html
        ErrorLog /srv/www/%sitename%/log/error.log
        CustomLog /srv/www/%sitename%/log/access.log combined
        <IfModule mod_dir.c>
            DirectoryIndex index.php index.html index.htm
        </IfModule>
        <IfModule mod_proxy_fcgi.c>
            <FilesMatch \.ph(p[3457]?|t|tml)$>
                SetHandler proxy:unix:/run/php/php7.2-fpm-%sitename%.sock|fcgi://%sitename%/
            </FilesMatch>
        </IfModule>
        <IfModule mod_alias.c>
            RedirectMatch 404 .*/\.git
        </IfModule>
    </Macro>
    <Macro PhpFpmVirtualHost72 %sitename%>
        Use PhpFpmVirtualHostCommon72 %sitename%
        <IfModule mod_proxy_fcgi.c>
            <Proxy fcgi://%sitename%/ enablereuse=on timeout=60>
            </Proxy>
            <LocationMatch ^/(status|ping)$>
                SetHandler proxy:unix:/run/php/php7.2-fpm-%sitename%.sock|fcgi://%sitename%/
                Require ip 127
            </LocationMatch>
        </IfModule>
    </Macro>
    <Macro PhpFpmVirtualHostSsl72 %sitename%>
        Use PhpFpmVirtualHostCommon72 %sitename%
    </Macro>
</IfModule>
EOF
    rm -f "/etc/apache2/sites-enabled"/*
    ln -s "../sites-available/${PATH_PREFIX}default.conf" "/etc/apache2/sites-enabled/000-${PATH_PREFIX}default.conf"
    log_file "/etc/apache2/sites-available/${PATH_PREFIX}default.conf"

    if [ -n "$HOST_DOMAIN" ]; then
        log "Adding site to Apache HTTPD: $HOST_DOMAIN"
        mkdir -p "/srv/www/$HOST_ACCOUNT/log"
        cat <<EOF >"/etc/apache2/sites-available/$HOST_ACCOUNT.conf"
<VirtualHost *:80>
    ServerName $HOST_DOMAIN
    ServerAlias www.$HOST_DOMAIN
    Use PhpFpmVirtualHost72 $HOST_ACCOUNT
</VirtualHost>
<VirtualHost *:443>
    ServerName $HOST_DOMAIN
    ServerAlias www.$HOST_DOMAIN
    Use PhpFpmVirtualHostSsl72 $HOST_ACCOUNT
</VirtualHost>
EOF
        ln -s "../sites-available/$HOST_ACCOUNT.conf" "/etc/apache2/sites-enabled/$HOST_ACCOUNT.conf"
        log_file "/etc/apache2/sites-available/$HOST_ACCOUNT.conf"

        log "Starting apache2.service"
        systemctl start apache2.service
    fi
fi

if is_installed mariadb-server; then
    log "Starting mysql.service (MariaDB)"
    systemctl start mysql.service
    if [ -n "$MYSQL_PASSWORD" ]; then
        MYSQL_USERNAME="${MYSQL_USERNAME:-dbadmin}"
        MYSQL_PASSWORD="${MYSQL_PASSWORD//\\/\\\\}"
        MYSQL_PASSWORD="${MYSQL_PASSWORD//\'/\\\'}"
        log "Creating MySQL administrator '$MYSQL_USERNAME'"
        echo "\
GRANT ALL PRIVILEGES ON *.* \
TO '$MYSQL_USERNAME'@'localhost' \
IDENTIFIED BY '$MYSQL_PASSWORD' \
WITH GRANT OPTION" | mysql -uroot
    fi
fi

log "==== $(basename "$0"): deployment complete"

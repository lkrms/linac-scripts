#!/bin/bash
# shellcheck disable=SC2001,SC2207
#
# <UDF name="NODE_HOSTNAME" label="Short hostname" example="web01-dev-syd" />
# <UDF name="NODE_FQDN" label="Host FQDN" example="web01-dev-syd.linode.linacreative.com" />
# <UDF name="NODE_TIMEZONE" label="System timezone" default="Australia/Sydney" />
# <UDF name="NODE_SERVICES" label="Services to install and configure" manyof="apache+php,mysql,fail2ban,wp-cli" default="" />
# <UDF name="HOST_DOMAIN" label="Initial hosting domain" example="clientname.com.au" default="" />
# <UDF name="HOST_ACCOUNT" label="Initial hosting account name (default: automatic)" example="clientname" default="" />
# <UDF name="ADMIN_USERS" label="Admin users to create (comma-delimited)" default="linac" />
# <UDF name="ADMIN_EMAIL" label="Forwarding address for system email" example="tech@linacreative.com" />
# <UDF name="TRUSTED_IP_ADDRESSES" label="Trusted IP addresses (comma-delimited)" example="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" default="" />
# <UDF name="MYSQL_USERNAME" label="MySQL admin username" example="dbadmin" default="" />
# <UDF name="MYSQL_PASSWORD" label="MySQL password (admin user not created if blank)" default="" />
# <UDF name="SMTP_RELAY" label="SMTP relay (system-wide)" example="[mail.clientname.com.au]:587" default="" />
# <UDF name="AUTO_REBOOT" label="Reboot automatically after unattended upgrades" oneof="Y,N" />
# <UDF name="AUTO_REBOOT_TIME" label="Preferred automatic reboot time" oneof="02:00,03:00,04:00,05:00,06:00,07:00,08:00,09:00,10:00,11:00,12:00,13:00,14:00,15:00,16:00,17:00,18:00,19:00,20:00,21:00,22:00,23:00,00:00,01:00,now" default="02:00" />
# <UDF name="PATH_PREFIX" label="Prefix for config files generated by this script" default="lk-" />
# <UDF name="SCRIPT_DEBUG" label="Enable debugging" oneof="Y,N" default="N" />

function is_installed() {
    local STATUS
    STATUS="$(dpkg-query --show --showformat '${db:Status-Status}' "$1" 2>/dev/null)" &&
        [ "$STATUS" = "installed" ]
}

function now() {
    date +'%Y-%m-%d %H:%M:%S %z'
}

function log() {
    {
        printf '%s %s\n' "$(now)" "$1"
        shift
        [ "$#" -eq "0" ] ||
            printf '  %s\n' "${@//$'\n'/$'\n  '}" ""
    } | tee -a "$LOG_FILE"
}

function die() {
    local EXIT_STATUS="$?"
    [ "$EXIT_STATUS" -ne "0" ] || EXIT_STATUS="1"
    log "==== $(basename "$0"): $1" "${@:2}"
    exit "$EXIT_STATUS"
}

# edit_file FILE SEARCH_PATTERN REPLACE_PATTERN ADD_TEXT
function edit_file() {
    if [ -f "$1" ]; then
        cp -nav "$1" "$1.orig"
    else
        [ -n "${4:-}" ] || die "file not found: $1"
    fi
    if grep -Eq "$2" "$1" 2>/dev/null; then
        sed -Ei "s/$2/$3/" "$1"
    elif [ -n "${4:-}" ]; then
        echo "$4" >>"$1"
    else
        die "no line matching $2 in $1"
    fi
    log_file "$1"
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
            log "Command failed:" "$*"
            log "Waiting $WAIT seconds"
            sleep "$WAIT"
            ((NEW_WAIT = WAIT + LAST_WAIT))
            LAST_WAIT="$WAIT"
            WAIT="$NEW_WAIT"
            log "Retrying (attempt $((++ATTEMPT))/$MAX_ATTEMPTS)"
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
    # TODO: replace with an HTTP-based notification mechanism
    if [ -n "${CALL_HOME_MX:-}" ]; then
        if [ "$EXIT_STATUS" -eq "0" ]; then
            SUBJECT="$NODE_FQDN deployed successfully"
        else
            SUBJECT="$NODE_FQDN failed to deploy"
        fi
        nc "$CALL_HOME_MX" 25 <<EOF || true
HELO $NODE_FQDN
MAIL FROM:<root@$NODE_FQDN>
RCPT TO:<$ADMIN_EMAIL>
DATA
From: ${PATH_PREFIX}hosting@Linode <root@$NODE_FQDN>
To: $NODE_HOSTNAME admin <$ADMIN_EMAIL>
Date: $(date -R)
Subject: $SUBJECT

Hi

The Linode at $NODE_HOSTNAME ($NODE_FQDN) is now live.
${EMAIL_INFO:+
$EMAIL_INFO
}
Install log:

<<<$LOG_FILE
$(cat "$LOG_FILE" 2>&1 || :)
>>>

Full output: $NODE_HOSTNAME:$OUT_FILE

.
QUIT
EOF
    fi
}

set -euo pipefail
shopt -s nullglob

if [ "${SCRIPT_DEBUG:-N}" = "Y" ]; then
    set -x
fi

PATH_PREFIX="${PATH_PREFIX:-lk-}"
LOCK_FILE="/tmp/${PATH_PREFIX}install.lock"
LOG_FILE="/var/log/${PATH_PREFIX}install.log"
OUT_FILE="/var/log/${PATH_PREFIX}install.out"

install -v -m 0640 -g "adm" "/dev/null" "$LOG_FILE"
install -v -m 0640 -g "adm" "/dev/null" "$OUT_FILE"

trap 'exit_trap' EXIT

exec 9>"$LOCK_FILE"
flock -n 9 || die "unable to acquire a lock on $LOCK_FILE"

exec > >(tee -a "$OUT_FILE") 2>&1

# TODO: more validation here
FIELD_ERRORS=()
PATH_PREFIX_ALPHA="$(sed 's/[^a-zA-Z0-9]//g' <<<"$PATH_PREFIX")"
[ -n "$PATH_PREFIX_ALPHA" ] || FIELD_ERRORS+=("PATH_PREFIX must contain at least one letter or number")
[ -n "${NODE_HOSTNAME:-}" ] || FIELD_ERRORS+=("NODE_HOSTNAME not set")
[ -n "${NODE_FQDN:-}" ] || FIELD_ERRORS+=("NODE_FQDN not set")
[ -n "${ADMIN_EMAIL:-}" ] || FIELD_ERRORS+=("ADMIN_EMAIL not set")
[ -n "${AUTO_REBOOT:-}" ] || FIELD_ERRORS+=("AUTO_REBOOT not set")
[ "${#FIELD_ERRORS[@]}" -eq "0" ] ||
    die "invalid field values" \
        "${FIELD_ERRORS[@]}"

NODE_TIMEZONE="${NODE_TIMEZONE:-Australia/Sydney}"
NODE_SERVICES="${NODE_SERVICES:-}"
HOST_DOMAIN="${HOST_DOMAIN:-}"
HOST_DOMAIN="${HOST_DOMAIN#www.}"
HOST_ACCOUNT="${HOST_ACCOUNT:-${HOST_DOMAIN%%.*}}"
ADMIN_USERS="${ADMIN_USERS:-linac}"
TRUSTED_IP_ADDRESSES="${TRUSTED_IP_ADDRESSES:-}"
MYSQL_USERNAME="${MYSQL_USERNAME:-}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
SMTP_RELAY="${SMTP_RELAY:-}"
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-02:00}"

# don't export privileged information to other commands
export -n \
    HOST_DOMAIN HOST_ACCOUNT \
    ADMIN_USERS MYSQL_USERNAME MYSQL_PASSWORD SMTP_RELAY

[ -s "/root/.ssh/authorized_keys" ] ||
    die "at least one SSH key must be added to Linodes deployed with this StackScript"

ADMIN_USER_KEYS="$([ -z "$ADMIN_USERS" ] || grep -E "\s(${ADMIN_USERS//,/|})\$" "/root/.ssh/authorized_keys" || :)"
HOST_KEYS="$([ -z "$ADMIN_USERS" ] && cat "/root/.ssh/authorized_keys" || grep -Ev "\s(${ADMIN_USERS//,/|})\$" "/root/.ssh/authorized_keys" || :)"

log "==== $(basename "$0"): preparing system"
log "Environment:" \
    "$(printenv | grep -v '^LS_COLORS=' | sort)"

. /etc/lsb-release

EXCLUDE_PACKAGES=()
case "$DISTRIB_RELEASE" in
*)
    # "-n" disables add-apt-repository's automatic package cache update
    ADD_APT_REPOSITORY_ARGS=(-yn)
    CERTBOT_REPO="ppa:certbot/certbot"
    PHPVER=7.2
    ;;&
16.04)
    # in 16.04, the package cache isn't automatically updated by default
    ADD_APT_REPOSITORY_ARGS=(-y)
    PHPVER=7.0
    ;;
20.04)
    unset CERTBOT_REPO
    PHPVER=7.4
    EXCLUDE_PACKAGES+=(php-gettext)
    ;;
esac

export DEBIAN_FRONTEND=noninteractive \
    DEBCONF_NONINTERACTIVE_SEEN=true \
    PIP_NO_INPUT=1

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

log "Enabling persistent journald storage"
edit_file "/etc/systemd/journald.conf" "^#?Storage=.*$" "Storage=persistent"
systemctl restart systemd-journald.service

log "Setting system hostname to '$NODE_HOSTNAME'"
hostnamectl set-hostname "$NODE_HOSTNAME"

FILE="/etc/hosts"
log "Adding entries for '$NODE_HOSTNAME' and '$NODE_FQDN' to $FILE"
cat <<EOF >>"$FILE"

# Added by $(basename "$0") at $(now)
127.0.1.1 $NODE_HOSTNAME${IPV4_ADDRESS:+
$IPV4_ADDRESS $NODE_FQDN}${IPV6_ADDRESS:+
$IPV6_ADDRESS $NODE_FQDN}
EOF
log_file "$FILE"

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
#!/bin/bash
# Created by $(basename "$0") at $(now)
$(declare -f now)
LOG=(
"==== \$(basename "\$0"): init script policy helper invoked"
"Arguments:
\$([ "\$#" -eq 0 ]||printf '  - %s\n' "\$@")")
DEPLOY_PENDING=N
EXIT_STATUS=0
exec 9>"/tmp/${PATH_PREFIX}install.lock"
if ! flock -n 9;then
DEPLOY_PENDING=Y
[ "\${DPKG_MAINTSCRIPT_NAME:-}" != postinst ]||EXIT_STATUS=101
fi
LOG+=("Deploy pending: \$DEPLOY_PENDING")
LOG+=("Exit status: \$EXIT_STATUS")
printf '%s %s\n%s\n' "\$(now)" "\${LOG[0]}" "\$(LOG=("\${LOG[@]:1}")
printf '  %s\n' "\${LOG[@]//\$'\n'/\$'\n'  }")" >>"/var/log/${PATH_PREFIX}install.log"
exit "\$EXIT_STATUS"
EOF
chmod a+x "/usr/sbin/policy-rc.d"
log_file "/usr/sbin/policy-rc.d"

REMOVE_PACKAGES=(
    mlocate # waste of CPU
    rsyslog # waste of space (assuming journald storage is persistent)

    # Canonical cruft
    landscape-common
    snapd
    ubuntu-advantage-tools
)
for i in "${!REMOVE_PACKAGES[@]}"; do
    is_installed "${REMOVE_PACKAGES[$i]}" ||
        unset "REMOVE_PACKAGES[$i]"
done
if [ "${#REMOVE_PACKAGES[@]}" -gt "0" ]; then
    log "Removing APT packages:" "${REMOVE_PACKAGES[*]}"
    apt-get -yq purge "${REMOVE_PACKAGES[@]}"
fi

log "Disabling unnecessary motd scripts"
for FILE in 10-help-text 50-motd-news 91-release-upgrade; do
    [ ! -x "/etc/update-motd.d/$FILE" ] || chmod -c a-x "/etc/update-motd.d/$FILE"
done

log "Configuring kernel parameters"
FILE="/etc/sysctl.d/90-${PATH_PREFIX}defaults.conf"
cat <<EOF >"$FILE"
# Created by $(basename "$0") at $(now)

# Avoid paging and swapping if at all possible
vm.swappiness = 1

# Apache and PHP-FPM both default to listen.backlog = 511, but the
# default value of SOMAXCONN is only 128
net.core.somaxconn = 1024
EOF
log_file "$FILE"
sysctl --system

log "Hardening default home directory permissions"
edit_file "/etc/login.defs" "^#?(UMASK\s+).*$" "\1027" $'UMASK\t\t027'

log "Sourcing /opt/${PATH_PREFIX}platform/server/.bashrc in ~/.bashrc for all users"
BASH_SKEL="
# Added by $(basename "$0") at $(now)
if [ -f '/opt/${PATH_PREFIX}platform/server/.bashrc' ]; then
    . '/opt/${PATH_PREFIX}platform/server/.bashrc'
fi"
echo "$BASH_SKEL" >>"/etc/skel/.bashrc"
if [ -f "/root/.bashrc" ]; then
    echo "$BASH_SKEL" >>"/root/.bashrc"
else
    cp "/etc/skel/.bashrc" "/root/.bashrc"
fi

DIR="/etc/skel.$PATH_PREFIX_ALPHA"
[ ! -e "$DIR" ] || die "already exists: $DIR"
log "Creating $DIR (for hosting accounts)"
cp -av "/etc/skel" "$DIR"
install -v -d -m 0755 "$DIR/.ssh"
install -v -m 0644 /dev/null "$DIR/.ssh/authorized_keys"
[ -z "$HOST_KEYS" ] || echo "$HOST_KEYS" >>"$DIR/.ssh/authorized_keys"

for USERNAME in ${ADMIN_USERS//,/ }; do
    FIRST_ADMIN="${FIRST_ADMIN:-$USERNAME}"
    log "Creating superuser '$USERNAME'"
    # HOME_DIR may already exist, e.g. if filesystems have been mounted in it
    useradd --no-create-home --groups "adm,sudo" --shell "/bin/bash" "$USERNAME"
    USER_GROUP="$(id -gn "$USERNAME")"
    USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
    install -v -d -m 0750 -o "$USERNAME" -g "$USER_GROUP" "$USER_HOME"
    sudo -Hu "$USERNAME" cp -nRTv "/etc/skel" "$USER_HOME"
    if [ -z "$ADMIN_USER_KEYS" ]; then
        [ ! -e "/root/.ssh" ] || {
            log "Moving /root/.ssh to /home/$USERNAME/.ssh"
            mv "/root/.ssh" "/home/$USERNAME/" &&
                chown -R "$USERNAME": "/home/$USERNAME/.ssh"
        }
    else
        install -v -d -m 0700 -o "$USERNAME" -g "$USER_GROUP" "$USER_HOME/.ssh"
        install -v -m 0600 -o "$USERNAME" -g "$USER_GROUP" /dev/null "$USER_HOME/.ssh/authorized_keys"
        grep -E "\s$USERNAME\$" <<<"$ADMIN_USER_KEYS" >>"$USER_HOME/.ssh/authorized_keys" || :
    fi
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >"/etc/sudoers.d/nopasswd-$USERNAME"
done

log "Disabling root password"
passwd -l root

# TODO: configure chroot jail
log "Disabling clear text passwords when authenticating with SSH"
sed -Ei.orig \
    "s/^#?(PasswordAuthentication${FIRST_ADMIN+|PermitRootLogin})\b.*/\1 no/" \
    /etc/ssh/sshd_config
systemctl restart sshd.service
FIRST_ADMIN="${FIRST_ADMIN:-root}"

log "Disabling email notifications related to failed sudo attempts"
cat <<EOF >"/etc/sudoers.d/${PATH_PREFIX}defaults"
# Created by $(basename "$0") at $(now)
Defaults !mail_no_user
Defaults !mail_badpass
EOF
log_file "/etc/sudoers.d/${PATH_PREFIX}defaults"

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
    git
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

    #
    build-essential
    python3
    python3-dev
)

# if service installations have been requested, add-apt-repository
# will need to be available
[ -z "$NODE_SERVICES" ] ||
    PACKAGES+=(software-properties-common)

debconf-set-selections <<EOF
postfix	postfix/main_mailer_type	select	Internet Site
postfix	postfix/mailname	string	$NODE_FQDN
postfix	postfix/relayhost	string	$SMTP_RELAY
postfix	postfix/root_address	string	$ADMIN_EMAIL
EOF

log "Installing APT packages:" "${PACKAGES[*]}"
keep_trying apt-get -yq install "${PACKAGES[@]}"

log "Setting system timezone to '$NODE_TIMEZONE'"
timedatectl set-timezone "$NODE_TIMEZONE"

log "Configuring apt-listchanges"
[ ! -e "/etc/apt/listchanges.conf" ] ||
    mv "/etc/apt/listchanges.conf" "/etc/apt/listchanges.conf.orig"
cat <<EOF >"/etc/apt/listchanges.conf"
[apt]
frontend=pager
which=both
email_address=root
email_format=html
confirm=false
headers=true
reverse=false
save_seen=/var/lib/apt/listchanges.db
EOF
log_file "/etc/apt/listchanges.conf"

FILE="/boot/config-$(uname -r)"
if [ -f "$FILE" ] && ! grep -Fxq "CONFIG_BSD_PROCESS_ACCT=y" "$FILE"; then
    log "Disabling atopacct.service (process accounting not available)"
    systemctl disable atopacct.service
fi

[ -e "/opt/${PATH_PREFIX}platform" ] || {
    log "Cloning 'https://github.com/lkrms/lk-platform.git' to '/opt/${PATH_PREFIX}platform'"
    install -v -d -m 2775 -o "$FIRST_ADMIN" -g "adm" "/opt/${PATH_PREFIX}platform"
    keep_trying sudo -Hu "$FIRST_ADMIN" \
        git clone "https://github.com/lkrms/lk-platform.git" \
        "/opt/${PATH_PREFIX}platform"
    export LK_BASE="/opt/${PATH_PREFIX}platform"
    install -v -d -m 2775 -o "$FIRST_ADMIN" -g "adm" "/opt/${PATH_PREFIX}platform/etc"
    set | grep -E '^(LK_BASE|NODE_(HOSTNAME|FQDN|TIMEZONE|SERVICES)|PATH_PREFIX|ADMIN_EMAIL)=' |
        sudo -Hu "$FIRST_ADMIN" tee "/opt/${PATH_PREFIX}platform/etc/server.conf" >/dev/null
}

# TODO: verify downloads
log "Installing pip, ps_mem, glances"
keep_trying curl --output /root/get-pip.py "https://bootstrap.pypa.io/get-pip.py"
python3 /root/get-pip.py
pip install ps_mem glances

log "Creating virtual host base directory at /srv/www"
install -v -d -m 0751 -g "adm" "/srv/www"

case ",$NODE_SERVICES," in
,,) ;;

*)
    REPOS=(
        ${CERTBOT_REPO+"$CERTBOT_REPO"}
    )
    grep -Eq \
        "^deb\s+http://\w+(\.\w+)*(:[0-9]+)?(/ubuntu)?/?\s+(\w+\s+)*$DISTRIB_CODENAME\s+(\w+\s+)*universe(\s|\$)" \
        /etc/apt/sources.list ||
        REPOS+=(universe)

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
        libapache2-mod-qos
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
        php-mbstring
        php-memcache
        php-memcached
        php-mysql
        php-opcache
        php-pear
        php-pspell
        php-readline
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

*,wp-cli,*)
    PACKAGES+=(
        php-cli
    )
    log "Downloading wp-cli to /usr/local/bin"
    keep_trying curl --output "/usr/local/bin/wp" "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
    chmod a+x "/usr/local/bin/wp"
    ;;&

*)
    PACKAGES=($(printf '%s\n' "${PACKAGES[@]}" | sort | uniq))
    [ "${#EXCLUDE_PACKAGES[@]}" -eq "0" ] ||
        PACKAGES=($(printf '%s\n' "${PACKAGES[@]}" | grep -Fxv "$(printf '%s\n' "${EXCLUDE_PACKAGES[@]}")"))

    log "Adding APT repositories:" "${REPOS[@]}"
    for REPO in "${REPOS[@]}"; do
        keep_trying add-apt-repository "${ADD_APT_REPOSITORY_ARGS[@]}" "$REPO"
    done

    log "Installing APT packages:" "${PACKAGES[*]}"
    keep_trying apt-get -q update
    keep_trying apt-get -yq install "${PACKAGES[@]}"

    if [ -n "$HOST_DOMAIN" ]; then
        COPY_SKEL=0
        id "$HOST_ACCOUNT" >/dev/null 2>&1 || {
            log "Creating user account '$HOST_ACCOUNT'"
            useradd --no-create-home --home-dir "/srv/www/$HOST_ACCOUNT" --shell "/bin/bash" "$HOST_ACCOUNT"
            COPY_SKEL=1
        }
        HOST_ACCOUNT_GROUP="$(id -gn "$HOST_ACCOUNT")"
        install -v -d -m 0750 -o "$HOST_ACCOUNT" -g "$HOST_ACCOUNT_GROUP" "/srv/www/$HOST_ACCOUNT"
        install -v -d -m 2775 -o "$HOST_ACCOUNT" -g "$HOST_ACCOUNT_GROUP" "/srv/www/$HOST_ACCOUNT/public_html"
        install -v -d -m 2550 -o "$HOST_ACCOUNT" -g "$HOST_ACCOUNT_GROUP" "/srv/www/$HOST_ACCOUNT/log"
        install -v -d -m 0750 -o "$HOST_ACCOUNT" -g "$HOST_ACCOUNT_GROUP" "/srv/www/$HOST_ACCOUNT/ssl"
        install -v -d -m 0750 -o "$HOST_ACCOUNT" -g "$HOST_ACCOUNT_GROUP" "/srv/www/$HOST_ACCOUNT/.cache"
        [ "$COPY_SKEL" -eq "0" ] || {
            sudo -Hu "$HOST_ACCOUNT" cp -nRTv "/etc/skel.$PATH_PREFIX_ALPHA" "/srv/www/$HOST_ACCOUNT" &&
                chmod -Rc -077 "/srv/www/$HOST_ACCOUNT/.ssh"
        }
        ! is_installed apache2 || {
            log "Adding user 'www-data' to group '$HOST_ACCOUNT_GROUP'"
            usermod --append --groups "$HOST_ACCOUNT_GROUP" "www-data"
        }
    fi
    ;;

esac

if is_installed fail2ban; then
    # TODO: configure jails other than sshd
    :
fi

if is_installed postfix; then
    log "Binding postfix to the loopback interface"
    /usr/sbin/postconf -e "inet_interfaces = loopback-only"
    log_file "/etc/postfix/main.cf"
    log_file "/etc/aliases"
fi

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

        # third-party
        qos
    )
    APACHE_MODS_ENABLED="$(a2query -m | grep -Eo '^[^ ]+' | sort | uniq || :)"
    APACHE_DISABLE_MODS=($(comm -13 <(printf '%s\n' "${APACHE_MODS[@]}" | sort | uniq) <(echo "$APACHE_MODS_ENABLED")))
    APACHE_ENABLE_MODS=($(comm -23 <(printf '%s\n' "${APACHE_MODS[@]}" | sort | uniq) <(echo "$APACHE_MODS_ENABLED")))
    [ "${#APACHE_DISABLE_MODS[@]}" -eq "0" ] || {
        log "Disabling Apache HTTPD modules:" "${APACHE_DISABLE_MODS[*]}"
        a2dismod --force "${APACHE_DISABLE_MODS[@]}"
    }
    [ "${#APACHE_ENABLE_MODS[@]}" -eq "0" ] || {
        log "Enabling Apache HTTPD modules:" "${APACHE_ENABLE_MODS[*]}"
        a2enmod --force "${APACHE_ENABLE_MODS[@]}"
    }

    # TODO: make PHP-FPM setup conditional
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
<Macro RequireTrusted>
    Require local${TRUSTED_IP_ADDRESSES:+
    Require ip ${TRUSTED_IP_ADDRESSES//,/ }}
</Macro>
<VirtualHost *:80>
    ServerAdmin $ADMIN_EMAIL
    DocumentRoot /var/www/html
    ErrorLog \${APACHE_LOG_DIR}/error.log
    CustomLog \${APACHE_LOG_DIR}/access.log combined
    <IfModule mod_status.c>
        <Location /httpd-status>
            SetHandler server-status
            Use RequireTrusted
        </Location>
    </IfModule>
    <IfModule mod_info.c>
        <Location /httpd-info>
            SetHandler server-info
            Use RequireTrusted
        </Location>
    </IfModule>
    <IfModule mod_qos.c>
        <Location /httpd-qos>
            SetHandler qos-viewer
            Use RequireTrusted
        </Location>
    </IfModule>
</VirtualHost>
<Macro PhpFpmVirtualHost${PHPVER//./} %sitename%>
    ServerAdmin $ADMIN_EMAIL
    DocumentRoot /srv/www/%sitename%/public_html
    ErrorLog /srv/www/%sitename%/log/error.log
    CustomLog /srv/www/%sitename%/log/access.log combined
    DirectoryIndex index.php index.html index.htm
    ProxyPassMatch ^/(.*\.php(/.*)?)\$ fcgi://%sitename%/srv/www/$HOST_ACCOUNT/public_html/\$1
    <LocationMatch ^/(php-fpm-(status|ping))\$>
        ProxyPassMatch fcgi://%sitename%/\$1
        Use RequireTrusted
    </LocationMatch>
    <IfModule mod_rewrite.c>
        RewriteEngine On
        RewriteRule ^/php-fpm-(status|ping)\$ - [END]
    </IfModule>
    <IfModule mod_alias.c>
        RedirectMatch 404 .*/\.git
    </IfModule>
</Macro>
<Macro PhpFpmVirtualHostSsl${PHPVER//./} %sitename%>
    Use PhpFpmVirtualHost${PHPVER//./} %sitename%
</Macro>
<Macro PhpFpmProxy${PHPVER//./} %sitename% %timeout%>
    <Proxy unix:/run/php/php$PHPVER-fpm-%sitename%.sock|fcgi://%sitename%>
        ProxySet enablereuse=Off timeout=%timeout%
    </Proxy>
</Macro>
EOF
    rm -f "/etc/apache2/sites-enabled"/*
    ln -s "../sites-available/${PATH_PREFIX}default.conf" "/etc/apache2/sites-enabled/000-${PATH_PREFIX}default.conf"
    log_file "/etc/apache2/sites-available/${PATH_PREFIX}default.conf"

    PHP_FPM_POOLS=("/etc/php/$PHPVER/fpm/pool.d"/*)
    if [ "${#PHP_FPM_POOLS[@]}" -gt "0" ]; then
        log "Disabling pre-installed PHP-FPM pools"
        install -v -d -m 0755 "/etc/php/$PHPVER/fpm/pool.d.orig"
        mv "${PHP_FPM_POOLS[@]}" "/etc/php/$PHPVER/fpm/pool.d.orig/"
    fi

    if [ -n "$HOST_DOMAIN" ]; then
        log "Adding site to Apache HTTPD: $HOST_DOMAIN"
        cat <<EOF >"/etc/apache2/sites-available/$HOST_ACCOUNT.conf"
<VirtualHost *:80>
    ServerName $HOST_DOMAIN
    ServerAlias www.$HOST_DOMAIN
    Use PhpFpmVirtualHost${PHPVER//./} $HOST_ACCOUNT
</VirtualHost>
<VirtualHost *:443>
    ServerName $HOST_DOMAIN
    ServerAlias www.$HOST_DOMAIN
    Use PhpFpmVirtualHostSsl${PHPVER//./} $HOST_ACCOUNT
    SSLEngine on
    SSLCertificateFile /srv/www/$HOST_ACCOUNT/ssl/$HOST_DOMAIN.cert
    SSLCertificateKeyFile /srv/www/$HOST_ACCOUNT/ssl/$HOST_DOMAIN.key
</VirtualHost>
# PhpFpmProxy${PHPVER//./} %sitename% %timeout%
#   %timeout% should correlate with \`request_terminate_timeout\`
#   in /etc/php/$PHPVER/fpm/pool.d/$HOST_ACCOUNT.conf
Use PhpFpmProxy${PHPVER//./} $HOST_ACCOUNT 300
EOF
        install -v -m 0640 -g "$HOST_ACCOUNT_GROUP" /dev/null "/srv/www/$HOST_ACCOUNT/log/error.log"
        install -v -m 0640 -g "$HOST_ACCOUNT_GROUP" /dev/null "/srv/www/$HOST_ACCOUNT/log/access.log"
        install -v -m 0640 -o "$HOST_ACCOUNT" -g "$HOST_ACCOUNT_GROUP" /dev/null "/srv/www/$HOST_ACCOUNT/ssl/$HOST_DOMAIN.cert"
        install -v -m 0640 -o "$HOST_ACCOUNT" -g "$HOST_ACCOUNT_GROUP" /dev/null "/srv/www/$HOST_ACCOUNT/ssl/$HOST_DOMAIN.key"

        log "Creating a self-signed SSL certificate for '$HOST_DOMAIN'"
        openssl genrsa \
            -out "/srv/www/$HOST_ACCOUNT/ssl/$HOST_DOMAIN.key" \
            2048
        openssl req -new \
            -key "/srv/www/$HOST_ACCOUNT/ssl/$HOST_DOMAIN.key" \
            -subj "/C=AU/CN=$HOST_DOMAIN" \
            -addext "subjectAltName = DNS:www.$HOST_DOMAIN" \
            -out "/srv/www/$HOST_ACCOUNT/ssl/$HOST_DOMAIN.csr"
        openssl x509 -req -days 365 \
            -in "/srv/www/$HOST_ACCOUNT/ssl/$HOST_DOMAIN.csr" \
            -signkey "/srv/www/$HOST_ACCOUNT/ssl/$HOST_DOMAIN.key" \
            -out "/srv/www/$HOST_ACCOUNT/ssl/$HOST_DOMAIN.cert"
        rm -f "/srv/www/$HOST_ACCOUNT/ssl/$HOST_DOMAIN.csr"

        ln -s "../sites-available/$HOST_ACCOUNT.conf" "/etc/apache2/sites-enabled/$HOST_ACCOUNT.conf"
        log_file "/etc/apache2/sites-available/$HOST_ACCOUNT.conf"

        log "Adding pool to PHP-FPM: $HOST_ACCOUNT"
        cat <<EOF >"/etc/php/$PHPVER/fpm/pool.d/$HOST_ACCOUNT.conf"
; Values in /etc/apache2/sites-available/$HOST_ACCOUNT.conf should be updated
; if \`request_terminate_timeout\` or \`pm.max_children\` are changed here
[$HOST_ACCOUNT]
user = \$pool
listen = /run/php/php$PHPVER-fpm-\$pool.sock
listen.owner = www-data
listen.group = www-data
; ondemand can't handle sudden bursts: https://github.com/php/php-src/pull/1308
pm = static
; tune based on memory consumed per process under load
pm.max_children = 8
; respawn occasionally in case of memory leaks
pm.max_requests = 10000
; because \`max_execution_time\` only counts CPU time
request_terminate_timeout = 300
; check \`ulimit -Hn\` and raise in /etc/security/limits.d/ if needed
rlimit_files = 1048576
pm.status_path = /php-fpm-status
ping.path = /php-fpm-ping
access.log = "/srv/www/\$pool/log/php$PHPVER-fpm.access.log"
access.format = "%{REMOTE_ADDR}e - %u %t \"%m %r%Q%q\" %s %f %{mili}d %{kilo}M %C%%"
catch_workers_output = yes
; tune based on system resources
php_admin_value[opcache.memory_consumption] = 256
php_admin_value[opcache.file_cache] = "/srv/www/$HOST_ACCOUNT/.cache/opcache"
php_admin_value[error_log] = "/srv/www/$HOST_ACCOUNT/log/php$PHPVER-fpm.error.log"
php_admin_flag[log_errors] = On
php_flag[display_errors] = Off
php_flag[display_startup_errors] = Off
EOF
        install -v -d -m 0700 -o "$HOST_ACCOUNT" -g "$HOST_ACCOUNT_GROUP" "/srv/www/$HOST_ACCOUNT/.cache/opcache"
        install -v -m 0640 -g "$HOST_ACCOUNT_GROUP" /dev/null "/srv/www/$HOST_ACCOUNT/log/php$PHPVER-fpm.access.log"
        install -v -m 0640 -g "$HOST_ACCOUNT_GROUP" /dev/null "/srv/www/$HOST_ACCOUNT/log/php$PHPVER-fpm.error.log"
        log_file "/etc/php/$PHPVER/fpm/pool.d/$HOST_ACCOUNT.conf"
    fi
fi

if is_installed mariadb-server; then
    # TODO: configure innodb_buffer_pool_size as a percentage of system memory
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
    # TODO: create $HOST_ACCOUNT database
fi

# TODO: add logrotate.d config
# TODO: add iptables rules
# TODO: collectd+nagios

log "Running apt-get autoremove"
apt-get -yq autoremove

log "==== $(basename "$0"): deployment complete; rebooting"
shutdown --reboot +"${REBOOT_DELAY:-0}"
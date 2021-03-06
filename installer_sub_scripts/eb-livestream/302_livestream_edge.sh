# -----------------------------------------------------------------------------
# LIVESTREAM_EDGE.SH
# -----------------------------------------------------------------------------
set -e
source $INSTALLER/000_source

# -----------------------------------------------------------------------------
# ENVIRONMENT
# -----------------------------------------------------------------------------
MACH="eb-livestream-edge"
cd $MACHINES/$MACH

ROOTFS="/var/lib/lxc/$MACH/rootfs"
DNS_RECORD=$(grep "address=/$MACH/" /etc/dnsmasq.d/eb_livestream | head -n1)
IP=${DNS_RECORD##*/}
SSH_PORT="30$(printf %03d ${IP##*.})"
echo LIVESTREAM_EDGE="$IP" >> $INSTALLER/000_source

# -----------------------------------------------------------------------------
# NFTABLES RULES
# -----------------------------------------------------------------------------
# public ssh
nft delete element eb-nat tcp2ip { $SSH_PORT } 2>/dev/null || true
nft add element eb-nat tcp2ip { $SSH_PORT : $IP }
nft delete element eb-nat tcp2port { $SSH_PORT } 2>/dev/null || true
nft add element eb-nat tcp2port { $SSH_PORT : 22 }
# http
nft delete element eb-nat tcp2ip { 80 } 2>/dev/null || true
nft add element eb-nat tcp2ip { 80 : $IP }
nft delete element eb-nat tcp2port { 80 } 2>/dev/null || true
nft add element eb-nat tcp2port { 80 : 80 }
# https
nft delete element eb-nat tcp2ip { 443 } 2>/dev/null || true
nft add element eb-nat tcp2ip { 443 : $IP }
nft delete element eb-nat tcp2port { 443 } 2>/dev/null || true
nft add element eb-nat tcp2port { 443 : 443 }

# -----------------------------------------------------------------------------
# INIT
# -----------------------------------------------------------------------------
[ "$DONT_RUN_LIVESTREAM_EDGE" = true ] && exit

echo
echo "-------------------------- $MACH --------------------------"

# -----------------------------------------------------------------------------
# CONTAINER SETUP
# -----------------------------------------------------------------------------
# stop the template container if it's running
set +e
lxc-stop -n eb-buster
lxc-wait -n eb-buster -s STOPPED
set -e

# remove the old container if exists
set +e
lxc-stop -n $MACH
lxc-wait -n $MACH -s STOPPED
lxc-destroy -n $MACH
rm -rf /var/lib/lxc/$MACH
sleep 1
set -e

# create the new one
lxc-copy -n eb-buster -N $MACH -p /var/lib/lxc/

# shared directories
mkdir -p $SHARED/cache
mkdir -p $SHARED/livestream

# container config
rm -rf $ROOTFS/var/cache/apt/archives
mkdir -p $ROOTFS/var/cache/apt/archives
rm -rf $ROOTFS/usr/local/eb/livestream
mkdir -p $ROOTFS/usr/local/eb/livestream
sed -i '/^lxc\.net\./d' /var/lib/lxc/$MACH/config
sed -i '/^# Network configuration/d' /var/lib/lxc/$MACH/config

cat >> /var/lib/lxc/$MACH/config <<EOF
lxc.mount.entry = $SHARED/livestream usr/local/eb/livestream none bind 0 0

# Network configuration
lxc.net.0.type = veth
lxc.net.0.link = $BRIDGE
lxc.net.0.name = eth0
lxc.net.0.flags = up
lxc.net.0.ipv4.address = $IP/24
lxc.net.0.ipv4.gateway = auto

# Start options
lxc.start.auto = 1
lxc.start.order = 500
lxc.start.delay = 2
lxc.group = eb-group
lxc.group = onboot
EOF

# start container
lxc-start -n $MACH -d
lxc-wait -n $MACH -s RUNNING
lxc-attach -n $MACH -- ping -c1 deb.debian.org || sleep 3

# -----------------------------------------------------------------------------
# HOSTNAME
# -----------------------------------------------------------------------------
lxc-attach -n $MACH -- \
    zsh -c \
    "set -e
     echo $MACH > /etc/hostname
     sed -i 's/\(127.0.1.1\s*\).*$/\1$MACH/' /etc/hosts
     hostname $MACH"

# -----------------------------------------------------------------------------
# PACKAGES
# -----------------------------------------------------------------------------
# fake install
lxc-attach -n $MACH -- \
    zsh -c \
    "set -e
     export DEBIAN_FRONTEND=noninteractive
     apt-get $APT_PROXY_OPTION -dy reinstall hostname"

# update
lxc-attach -n $MACH -- \
    zsh -c \
    "set -e
     export DEBIAN_FRONTEND=noninteractive
     apt-get -y --allow-releaseinfo-change update
     apt-get $APT_PROXY_OPTION -y dist-upgrade"

# packages
lxc-attach -n $MACH -- \
    zsh -c \
    "set -e
     export DEBIAN_FRONTEND=noninteractive
     apt-get $APT_PROXY_OPTION -y install ssl-cert ca-certificates certbot
     apt-get $APT_PROXY_OPTION -y install nginx-extras php-fpm"

# -----------------------------------------------------------------------------
# SYSTEM CONFIGURATION
# -----------------------------------------------------------------------------
# ssl
lxc-attach -n $MACH -- \
    zsh -c \
    "set -e
     ln -s ssl-cert-snakeoil.pem /etc/ssl/certs/ssl-eb.pem
     ln -s ssl-cert-snakeoil.key /etc/ssl/private/ssl-eb.key"

# set-letsencrypt-cert
cp $MACHINES/common/usr/local/sbin/set-letsencrypt-cert $ROOTFS/usr/local/sbin/
chmod 744 $ROOTFS/usr/local/sbin/set-letsencrypt-cert

# nginx
cp etc/nginx/snippets/eb_ssl.conf $ROOTFS/etc/nginx/snippets/
cp etc/nginx/sites-available/livestream-edge \
    $ROOTFS/etc/nginx/sites-available/
ln -s ../sites-available/livestream-edge $ROOTFS/etc/nginx/sites-enabled/
rm $ROOTFS/etc/nginx/sites-enabled/default

lxc-attach -n $MACH -- systemctl stop nginx.service
lxc-attach -n $MACH -- systemctl start nginx.service

# certbot service
mkdir -p $ROOTFS/etc/systemd/system/certbot.service.d
cp ../common/etc/systemd/system/certbot.service.d/override.conf \
    $ROOTFS/etc/systemd/system/certbot.service.d/
lxc-attach -n $MACH -- systemctl daemon-reload

# -----------------------------------------------------------------------------
# VIDEO PLAYERS
# -----------------------------------------------------------------------------
rm -rf $SHARED/livestream/hlsplayer
rm -rf $SHARED/livestream/dashplayer

cp -arp usr/local/eb/livestream/hlsplayer $SHARED/livestream/
cp -arp usr/local/eb/livestream/dashplayer $SHARED/livestream/
lxc-attach -n $MACH -- \
    zsh -c \
    "set -e
     chown www-data: /usr/local/eb/livestream/hlsplayer -R
     chown www-data: /usr/local/eb/livestream/dashplayer -R"

# -----------------------------------------------------------------------------
# WELCOME PAGE
# -----------------------------------------------------------------------------
cp usr/local/eb/index.html $ROOTFS/usr/local/eb/

# -----------------------------------------------------------------------------
# CONTAINER SERVICES
# -----------------------------------------------------------------------------
lxc-stop -n $MACH
lxc-wait -n $MACH -s STOPPED
lxc-start -n $MACH -d
lxc-wait -n $MACH -s RUNNING

# -----------------------------------------------------------------------------
# HOST CUSTOMIZATION FOR EB-LIVESTREAM-EDGE
# -----------------------------------------------------------------------------
cp $MACHINES/eb-livestream-host/usr/local/sbin/set-letsencrypt-cert \
    /usr/local/sbin/
chmod 744 /usr/local/sbin/set-letsencrypt-cert

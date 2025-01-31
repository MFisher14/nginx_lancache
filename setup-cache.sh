#!/bin/bash
set -e

# ======================================================================
# Various variables

TZ="US/Eastern"
NETDATA_URL="https://my-netdata.io/kickstart.sh"
NGINX_CONF_URL="https://raw.githubusercontent.com/MFisher14/nginx_lancache/refs/heads/master/etc/nginx/nginx.conf"
NAMED_CONF_URL="https://raw.githubusercontent.com/MFisher14/nginx_lancache/refs/heads/master/etc/named.conf"
DEFAULT_IPADDRESS="1.2.3.4"

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ipaddress) IPADDRESS="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Use default IP address if not provided
IPADDRESS=${IPADDRESS:-$DEFAULT_IPADDRESS}

# ======================================================================
# Check if we're running Debian or Ubuntu.

DEBIAN_STR="NAME=\"Debian GNU/Linux\""
UBUNTU_STR="NAME=\"Ubuntu\""

if grep -q "$DEBIAN_STR" /etc/os-release; then
  DISTRO="Debian"
elif grep -q "$UBUNTU_STR" /etc/os-release; then
  DISTRO="Ubuntu"
else
  echo "This script is only tested with Debian and Ubuntu. Exiting now."
  exit 1
fi

dpkg-reconfigure -f noninteractive ca-certificates

# ======================================================================
# Update the OS

DEBIAN_FRONTEND=noninteractive apt update && apt full-upgrade -y

# ======================================================================
# Install NGINX and other useful packages

DEBIAN_FRONTEND=noninteractive apt install -y sudo curl vim nginx libnginx-mod-stream unattended-upgrades bind9

# ======================================================================
# Set up unattended upgrades

if [ $DISTRO = "Debian" ]; then
  UNATTEND_CONF='/etc/apt/apt.conf.d/50unattended-upgrades'
  sed -i -e '/Unattended-Upgrade::Origins-Pattern {/ a\        "o=Netdata,l=Netdata";' \
    -e '/Unattended-Upgrade::Origins-Pattern {/ a\        "o=amplify,l=stable";' \
    -e '/\/\/\s*"origin=Debian,codename=${distro_codename}-updates";/ s,//\s*,        ,g' \
    -e '/\/\/Unattended-Upgrade::Automatic-Reboot-Time "02:00";/ s,//,,g' \
    -e 's|//Unattended-Upgrade::Automatic-Reboot "false";|Unattended-Upgrade::Automatic-Reboot "true";|' $UNATTEND_CONF
elif [ $DISTRO = "Ubuntu" ]; then
  UNATTEND_CONF='/etc/apt/apt.conf.d/50unattended-upgrades'
  sed -i -e "/Unattended-Upgrade::Allowed-Origins {/ i\Unattended-Upgrade::Origins-Pattern {\n        \"o=Netdata,l=Netdata\";\n};" \
    -e '/\/\/\s*"${distro_id}:${distro_codename}-updates";/ s,//\s*,        ,g' \
    -e '/\/\/Unattended-Upgrade::Automatic-Reboot-Time "02:00";/ s,//,,g' \
    -e 's|//Unattended-Upgrade::Automatic-Reboot "false";|Unattended-Upgrade::Automatic-Reboot "true";|' $UNATTEND_CONF
else
  echo "Unable to reliably set up unattended upgrade configuration, exiting."
  exit 1
fi

echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades
systemctl restart unattended-upgrades.service

# ======================================================================
# Backup stock NGINX config and overwrite with cache config, then restart

mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.old

mkdir -p /var/cache/nginx

curl -fsSL -o /etc/nginx/nginx.conf $NGINX_CONF_URL

systemctl restart nginx.service

# ======================================================================
# Download and setup Netdata

curl -fsSL $NETDATA_URL > /tmp/netdata-kickstart.sh && sh /tmp/netdata-kickstart.sh --stable-channel --non-interactive --disable-telemetry

cat << EOF > /etc/netdata/go.d/nginx.conf
jobs:
  - name: local
    url: http://127.0.0.1:8080/nginx_status
EOF

# ======================================================================
# Check if /etc/named/ folder exists
if [ ! -d /etc/named ]; then
    mkdir /etc/named
fi

# Check if /etc/named/intercept.zone exists
if [ -f /etc/named/intercept.zone ]; then
    mv /etc/named/intercept.zone /etc/named/.intercept.zone.bak
fi

# Create a new /etc/named/intercept.zone file
cat << EOF > /etc/named/intercept.zone
$TTL    604800
@       IN      SOA     localhost. root.localhost. (
                              2         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL

@       IN      NS      localhost.
; Change these IP's to the IP that you give your cache
@       IN      A       $IPADDRESS
*       IN      A       $IPADDRESS
EOF

# Replace /etc/named.conf with the one from the repo
if [ -f /etc/named.conf ]; then
    mv /etc/named.conf /etc/.named.conf.bak
fi

curl -fsSL -o /etc/named.conf $NAMED_CONF_URL

# Check if /etc/bind/db.root.domain exists
if [ -f /etc/bind/db.root.domain ]; then
    mv /etc/bind/db.root.domain /etc/bind/.db.root.domain.bak
fi

cat << EOF > /etc/bind/db.root.domain
;
; BIND data file for local loopback interface
;
$TTL	5m
@	IN	SOA	localhost. admin.localhost. (
			      3		; Serial
			     4h		; Refresh
			    15m		; Retry
			     8h		; Expire
			     4m )	; Negative Cache TTL
;
@	IN	NS	ns1.$IPADDRESS.lan.
@	IN	A	$IPADDRESS
EOF

# Check if /etc/bind/db.wildcard.domain exists
if [ -f /etc/bind/db.wildcard.domain ]; then
    mv /etc/bind/db.wildcard.domain /etc/bind/.db.wildcard.domain.bak
fi

# Create a new /etc/bind/db.wildcard.domain file
cat << EOF > /etc/bind/db.wildcard.domain
;
; BIND data file for local loopback interface
;
$TTL	5m
@	IN	SOA	localhost. admin.localhost. (
			      3		; Serial
			     4h		; Refresh
			    15m		; Retry
			     8h		; Expire
			     4m )	; Negative Cache TTL
;
@	IN	NS	ns1.$IPADDRESS.lan.
*	IN	A	$IPADDRESS
EOF

# Check if /etc/bind/db.wildcard.root.domain exists
if [ -f /etc/bind/db.wildcard.root.domain ]; then
    mv /etc/bind/db.wildcard.root.domain /etc/bind/.db.wildcard.root.domain.bak
fi

# Create a new /etc/bind/db.wildcard.root.domain file
cat << EOF > /etc/bind/db.wildcard.root.domain
;
; BIND data file for local loopback interface
;
$TTL	5m
@	IN	SOA	localhost. admin.localhost. (
			      3		; Serial
			     4h		; Refresh
			    15m		; Retry
			     8h		; Expire
			     4m )	; Negative Cache TTL
;
@	IN	NS	ns1.$IPADDRESS.lan.
@	IN	A	$IPADDRESS
*	IN	A	$IPADDRESS
EOF

# Check if /etc/bind/named.conf.local exists
if [ -f /etc/bind/named.conf.local ]; then
    mv /etc/bind/named.conf.local /etc/bind/.named.conf.local.bak
fi

# Create a new /etc/bind/named.conf.local file
cat << EOF > /etc/bind/named.conf.local
//
// Do any local configuration here
//

// Consider adding the 1918 zones here, if they are not used in your
// organization
//include "/etc/bind/zones.rfc1918";

include "/etc/bind/zones.microsoft";
include "/etc/bind/zones.google";
include "/etc/bind/zones.adobe";
EOF

# Check if /etc/bind/named.conf.options exists

if [ -f /etc/bind/named.conf.options ]; then
    mv /etc/bind/named.conf.options /etc/bind/.named.conf.options.bak
fi

# Create a new /etc/bind/named.conf.options file

cat << EOF > /etc/bind/named.conf.options
options {
	directory "/var/cache/bind";

	recursion yes;
	forward only;
	listen-on { any; };
	allow-query { any; };

	forwarders {
		8.8.8.8;
		8.8.4.4;
	};

	// If there is a firewall between you and nameservers you want
	// to talk to, you may need to fix the firewall to allow multiple
	// ports to talk.  See http://www.kb.cert.org/vuls/id/800113

	// If your ISP provided one or more IP addresses for stable 
	// nameservers, you probably want to use them as forwarders.  
	// Uncomment the following block, and insert the addresses replacing 
	// the all-0's placeholder.

	// forwarders {
	// 	0.0.0.0;
	// };

	//========================================================================
	// If BIND logs error messages about the root key being expired,
	// you will need to update your keys.  See https://www.isc.org/bind-keys
	//========================================================================
	dnssec-validation auto;

	listen-on-v6 { any; };
};
EOF

# Check if /etc/bind/zones.adobe exists
if [ -f /etc/bind/zones.adobe ]; then
    mv /etc/bind/zones.adobe /etc/bind/.zones.adobe.bak
fi
cat << EOF > /etc/bind/zones.adobe
// Adobe Zones
zone "ardownload.adobe.com" {
	type master;
	file "/etc/bind/db.root.domain";
	allow-transfer { none; };
};

zone "ccmdl.adobe.com" {
	type master;
	file "/etc/bind/db.root.domain";
	allow-transfer { none; };
};

zone "agsupdate.adobe.com" {
	type master;
	file "/etc/bind/db.root.domain";
	allow-transfer { none; };
};
EOF

# Check if /etc/bind/zones.google exists
if [ -f /etc/bind/zones.google ]; then
    mv /etc/bind/zones.google /etc/bind/.zones.google.bak
fi
cat << EOF > /etc/bind/zones.google
// Google Zones
zone "dl.google.com" {
	type master;
	file "/etc/bind/db.root.domain";
	allow-transfer { none; };
};

zone "gvt1.com" {
	type master;
	file "/etc/bind/db.wildcard.domain";
	allow-transfer { none; };
};
EOF

# Check if /etc/bind/zones.microsoft exists
if [ -f /etc/bind/zones.microsoft ]; then
    mv /etc/bind/zones.microsoft /etc/bind/.zones.microsoft.bak
fi
cat << EOF > /etc/bind/zones.microsoft
// Microsoft Zones
zone "download.windowsupdate.com" {
	type master;
	file "/etc/bind/db.wildcard.root.domain";
	allow-transfer { none; };
};

zone "tlu.dl.delivery.mp.microsoft.com" {
	type master;
	file "/etc/bind/db.wildcard.root.domain";
	allow-transfer { none; };
};

zone "officecdn.microsoft.com" {
	type master;
	file "/etc/bind/db.root.domain";
	allow-transfer { none; };
};

zone "officecdn.microsoft.com.edgesuite.net" {
	type master;
	file "/etc/bind/db.root.domain";
	allow-transfer { none; };
};
EOF

# Inform user if default IP address is used
if [ "$IPADDRESS" = "$DEFAULT_IPADDRESS" ]; then
    echo "IP address not provided. Using default IP address: $DEFAULT_IPADDRESS"
    echo "You will need to modify the following files to update the IP address:"
    echo "/etc/named/intercept.zone"
    echo "/etc/bind/named.conf.options"
fi


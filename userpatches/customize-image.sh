#!/usr/bin/env bash
set -euo pipefail

# This script runs inside the Armbian chroot during image creation.
# It installs and configures evcc, cockpit, and caddy in a single consolidated script.

echo "[customize-image] starting"

# Load environment variables
echo "[customize-image] loading environment variables"

# Load parameters injected by outer build script
ENV_FILE="/tmp/overlay/evcc-image.env"

if [[ -f "$ENV_FILE" ]]; then
	echo "[customize-image] Sourcing environment file"
	set -a
	# shellcheck disable=SC1090
	source "$ENV_FILE"
	set +a
fi

# Set defaults
export EVCC_HOSTNAME=${EVCC_HOSTNAME:-evcc}
export TIMEZONE=${TIMEZONE:-Europe/Berlin}
export DEBIAN_FRONTEND=noninteractive
export OPENWB=${OPENWB:-false}
export OPENWB_DISPLAY=${OPENWB_DISPLAY:-false}

echo "[customize-image] hostname=$EVCC_HOSTNAME tz=$TIMEZONE openwb=$OPENWB display=$OPENWB_DISPLAY"

# ============================================================================
# SYSTEM SETUP
# ============================================================================
echo "[customize-image] setting up system"

# Update system packages
apt-get update
apt-get -y upgrade

# Install base utils and mdns (avahi)
apt-get install -y --no-install-recommends \
	curl ca-certificates gnupg apt-transport-https \
	avahi-daemon avahi-utils libnss-mdns \
	sudo python3-gi python3-dbus

# Set timezone
apt-get install -y --no-install-recommends tzdata
echo "$TIMEZONE" >/etc/timezone
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true

# Set hostname and mdns
echo "$EVCC_HOSTNAME" > /etc/hostname
sed -i "s/127.0.1.1\s\+.*/127.0.1.1\t$EVCC_HOSTNAME/" /etc/hosts || true

# SSH hardening (Armbian/Debian Trixie): use drop-in to override defaults
mkdir -p /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-evcc.conf <<'SSHD'
# Disable SSH login for root
PermitRootLogin no
SSHD

# Lock the root account to prevent any login
passwd -l root

# Disable Armbian interactive first login wizard
systemctl disable armbian-firstlogin.service || true
rm -f /root/.not_logged_in_yet || true

# Add missing gpio group, which is actually used by udev already to set the gpio permissions correctly
groupadd --system gpio

# Create admin user with initial password and require password change on first login
if ! id -u admin >/dev/null 2>&1; then
	useradd -s /bin/bash --create-home -G sudo,netdev admin 
	echo 'admin:admin' | chpasswd
fi

# Enable mDNS service
systemctl enable avahi-daemon || true

# Ensure root home exists for Cockpit terminal (normally present)
test -d /root || mkdir -p /root
chown -R root:root /root

# ============================================================================
# COMITUP WIFI SETUP
# ============================================================================
echo "[customize-image] setting up comitup for wifi configuration"

# Install latest comitup from official repository (fixes device type compatibility)
curl -L -o /tmp/davesteele-comitup-apt-source.deb \
	"https://davesteele.github.io/comitup/deb/davesteele-comitup-apt-source_1.3_all.deb"
dpkg -i /tmp/davesteele-comitup-apt-source.deb || apt-get install -f -y
apt-get update
apt-get install -y --no-install-recommends comitup
rm -f /tmp/davesteele-comitup-apt-source.deb

# Clean up any potential interface conflicts
rm -f /etc/network/interfaces || true

# Mask conflicting services per official comitup documentation
systemctl mask dhcpcd.service || true
systemctl mask wpa-supplicant.service || true

# Configure systemd-resolved to not conflict with dnsmasq (needed for DHCP)
mkdir -p /etc/systemd/resolved.conf.d
cat >/etc/systemd/resolved.conf.d/comitup.conf <<'RESOLVEDCONF'
[Resolve]
# Don't bind to port 53 - let dnsmasq use it for AP mode DHCP
DNSStubListener=no
RESOLVEDCONF

# Ensure dnsmasq is available for comitup DHCP functionality
apt-get install -y --no-install-recommends dnsmasq
# Keep dnsmasq disabled - comitup will manage it when needed  
systemctl stop dnsmasq.service || true
systemctl disable dnsmasq.service || true
systemctl mask dnsmasq.service || true

# Enable NetworkManager (comitup manages dnsmasq and hostapd automatically)
systemctl enable NetworkManager.service || true

# Configure comitup with minimal settings
cat >/etc/comitup.conf <<'COMITUPCONF'
ap_name: evcc-setup
enable_appliance_mode: false
COMITUPCONF

# One-time WiFi setup check: only start AP if no internet at boot
cat >/usr/local/bin/evcc-wifi-setup.sh <<'WIFISETUP'
#!/bin/bash
# Start WiFi setup AP only if no internet connection after boot

# Give ethernet/network 45 seconds to establish (increased for reliability)
sleep 45

# Multiple internet connectivity checks for reliability
INTERNET_AVAILABLE=false

# Check 1: NetworkManager connectivity (accept both 'full' and 'portal')
CONNECTIVITY=$(nmcli networking connectivity check 2>/dev/null)
if echo "$CONNECTIVITY" | grep -qE 'full|portal'; then
	INTERNET_AVAILABLE=true
	echo "NetworkManager reports connectivity: $CONNECTIVITY"
fi

# Check 2: Ping test as fallback
if [[ "$INTERNET_AVAILABLE" == "false" ]]; then
	if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
		INTERNET_AVAILABLE=true
		echo "Ping test confirms internet connectivity"
	fi
fi

# Start AP only if no internet detected AND WiFi hardware exists
if [[ "$INTERNET_AVAILABLE" == "false" ]]; then
	# Check if WiFi hardware exists
	if ls /sys/class/net/wl* >/dev/null 2>&1 || iwconfig 2>/dev/null | grep -q "IEEE 802.11"; then
		# Unmask comitup first in case it was masked from previous boot
		systemctl unmask comitup.service >/dev/null 2>&1 || true
		systemctl enable comitup.service >/dev/null 2>&1 || true
		systemctl start comitup.service >/dev/null 2>&1 || true
		echo "No internet detected - WiFi setup AP started"
	else
		echo "No internet detected but no WiFi hardware found - skipping WiFi setup"
	fi
else
	# Internet available - ensure comitup is stopped and cleanup hotspot
	echo "Stopping comitup service..."

	# First try graceful stop with timeout
	timeout 10 systemctl stop comitup.service 2>&1 || {
		echo "Graceful stop failed, forcing kill..."
		systemctl kill comitup.service 2>&1 || true
		sleep 2
	}
		
	# Reset any failed state before disabling
	systemctl reset-failed comitup.service 2>&1 || true

	# Just disable, don't mask - this prevents "failed" status in Cockpit
	systemctl disable comitup.service 2>&1 || echo "Disable failed"

	# Clean up any active hotspot connections
	HOTSPOT_CONN=$(nmcli -t -f NAME connection show --active | grep "evcc-setup" || true)
	if [[ -n "$HOTSPOT_CONN" ]]; then
		echo "Cleaning up hotspot connection: $HOTSPOT_CONN"
		nmcli connection down "$HOTSPOT_CONN" 2>/dev/null || true
		nmcli connection delete "$HOTSPOT_CONN" 2>/dev/null || true
	fi
		
	echo "Internet available - WiFi setup stopped"
fi
WIFISETUP

chmod +x /usr/local/bin/evcc-wifi-setup.sh

# Create systemd service for one-time WiFi setup check
cat >/etc/systemd/system/evcc-wifi-setup.service <<'WIFISERVICE'
[Unit]
Description=Start WiFi setup if no internet at boot
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/evcc-wifi-setup.sh

[Install]
WantedBy=multi-user.target
WIFISERVICE

# Enable the one-time WiFi setup check
systemctl enable evcc-wifi-setup.service || true

# Create NetworkManager configuration for comitup compatibility
cat >/etc/NetworkManager/conf.d/comitup.conf <<'NMCONF'
[main]
unmanaged-devices=interface-name:comitup-*,type:wifi-p2p

[device]
wifi.scan-rand-mac-address=no

[connectivity]
uri=http://detectportal.firefox.com/canonical.html
interval=300
NMCONF

# ============================================================================
# Setup for OpenWB with display 
# ============================================================================
if [[ "$OPENWB_DISPLAY" == "true" ]]; then
	echo "[customize-image] OpenWB with display customizations"
	apt-get install -y --no-install-recommends labwc wayfire seatd xdg-user-dirs firefox-esr swayidle wlopm

	usermod -aG video,render admin  # video, render are required for starting labwc/wayland

	mkdir -p /home/admin/.config/labwc
	cat >/home/admin/.config/labwc/autostart <<-'LABWCAUTOSTART'
	/usr/bin/firefox --kiosk http://localhost:7070/ &
	/usr/bin/swayidle -w timeout 600 'wlopm --off \*' resume 'wlopm --on \*' &
	LABWCAUTOSTART

	mkdir -p /home/admin/.config/systemd/user
	cat >/home/admin/.config/systemd/user/kiosk.service <<-'KIOSKSERVICE'
	[Unit]
	Description=Start Kiosk mode
	[Service]
	Type=simple
	ExecStart=/usr/bin/labwc
	[Install]
	WantedBy=default.target
	KIOSKSERVICE

	# Enable auto-start of kiosk mode
	mkdir -p /home/admin/.config/systemd/user/default.target.wants
	ln -sf /home/admin/.config/systemd/user/kiosk.service /home/admin/.config/systemd/user/default.target.wants/kiosk.service
	
	# Fake loginctl enable-linger admin
	mkdir -p /var/lib/systemd/linger/
	touch /var/lib/systemd/linger/admin

	# Fix permissions of created files/directories
	chown -R admin:admin /home/admin/.config
	chmod 755 /home/admin/.config
fi

# ============================================================================
# EVCC SETUP
# ============================================================================
echo "[customize-image] setting up evcc"

# Install evcc via APT repository per docs
curl -1sLf 'https://dl.evcc.io/public/evcc/stable/setup.deb.sh' | bash -E

apt-get update
apt-get install -y evcc

# Configure evcc via systemd environment variables
mkdir -p /etc/systemd/system/evcc.service.d
cat >/etc/systemd/system/evcc.service.d/override.conf <<-EVCCCONF
[Service]
Environment="EVCC_NETWORK_HOST=${EVCC_HOSTNAME}.local"
Environment="EVCC_NETWORK_EXTERNALURL=https://${EVCC_HOSTNAME}.local"
Environment="EVCC_OCPP_PORT=8886"
EVCCCONF

if [[ "$OPENWB" == "true" ]]; then
	cat >>/etc/evcc.yaml.example <<-YAML
	network:
	  schema: https
	  host: ${EVCC_HOSTNAME}.local

	# Device used for meters and chargers can be either /dev/ttyUSB0 or /dev/ttyACM0 depending on installed modbus converter
	meters:      # Uncomment one of the following meters depending on which one is installed in your OpenWB
	- type: template
	  template: abb-ab
	  id: 201
	  device: /dev/ttyUSB0
	  baudrate: 9600
	  comset: 8N1
	  usage: charge
	  modbus: rs485serial
	  name: openwb-meter
	#- type: template
	#  template: mpm3pm
	#  id: 5
	#  device: /dev/ttyUSB0
	#  baudrate: 9600
	#  comset: 8N1
	#  usage: charge
	#  modbus: rs485serial
	#  name: openwb-meter
	#- type: template
	#  template: eastron
	#  id: 105
	#  device: /dev/ttyUSB0
	#  baudrate: 9600
	#  comset: 8N1
	#  usage: charge
	#  modbus: rs485serial
	#  name: openwb-meter

	chargers:
	- type: template
	  template: openwb-native
	  modbus: rs485serial
	  id: 1                   # EVSE is on Modbus Id 1
	  device: /dev/ttyUSB0
	  baudrate: 9600
	  comset: 8N1
	  name: openwb-charger
	  phases1p3p: true

	loadpoints:
	- title: MyLoadpoint
	  charger: openwb-charger
	  meter: openwb-meter

	site:
	  title: MyHome
	YAML

	# Add necessary groups to allow user evcc to access OpenWB HW
	usermod -aG dialout,input,gpio evcc
fi

# Enable evcc service
systemctl enable evcc || true

# ============================================================================
# COCKPIT SETUP
# ============================================================================
echo "[customize-image] setting up cockpit"

# Add AllStarLink repository for cockpit-wifimanager
curl -L -o /tmp/asl-apt-repos.deb13_all.deb \
	"https://repo.allstarlink.org/public/asl-apt-repos.deb13_all.deb"
dpkg -i /tmp/asl-apt-repos.deb13_all.deb || apt-get install -f -y
apt-get update
rm -f /tmp/asl-apt-repos.deb13_all.deb

# Install Cockpit and related packages
# Note: cockpit-pcp functionality is now built into cockpit-bridge in version 337+
apt-get install -y --no-install-recommends cockpit \
	packagekit cockpit-packagekit \
	cockpit-networkmanager \
	cockpit-wifimanager

# Cockpit configuration
mkdir -p /etc/cockpit
cat >/etc/cockpit/cockpit.conf <<'COCKPITCONF'
[WebService]
LoginTo = false
LoginTitle = "evcc"
COCKPITCONF

# Simple PolicyKit rule - admin user can do everything without authentication
mkdir -p /etc/polkit-1/rules.d
cat >/etc/polkit-1/rules.d/10-admin.rules <<'POLKIT'
// Admin user has full system access without password prompts
polkit.addRule(function(action, subject) {
	if (subject.user == "admin") {
		return polkit.Result.YES;
	}
});
POLKIT

# Enable services
systemctl enable cockpit.socket || true
systemctl enable packagekit || true

# ============================================================================
# CADDY SETUP
# ============================================================================
echo "[customize-image] setting up caddy"

# Install Caddy
apt-get install -y --no-install-recommends caddy

# Caddy configuration with internal TLS and reverse proxy to evcc:80
mkdir -p /etc/caddy
cat >/etc/caddy/Caddyfile <<CADDY
{
  email admin@example.com
  auto_https disable_redirects
  skip_install_trust
}

# HTTPS on 443 with Caddy internal TLS
https:// {
	tls internal {
		on_demand
	}
	encode zstd gzip
	log
	reverse_proxy 127.0.0.1:7070
}

# OCPP port forwarding: 8886 (HTTP) -> 8887 (HTTPS)
:8887 {
  tls internal {
    protocols tls1.2 tls1.3
  }
  log
  reverse_proxy 127.0.0.1:8886
}

CADDY

# Enable Caddy service
systemctl enable caddy || true

# ============================================================================
# UNATTENDED SECURITY UPDATES
# ============================================================================
echo "[customize-image] setting up unattended security updates"

# Install and enable unattended-upgrades (defaults to security-only in Debian 12)
apt-get install -y --no-install-recommends unattended-upgrades
echo 'APT::Periodic::Unattended-Upgrade "1";' > /etc/apt/apt.conf.d/20auto-upgrades

echo "[customize-image] unattended security updates enabled"

# ============================================================================
# BRANDING
# ============================================================================
echo "[customize-image] customizing branding"

if [[ -f /etc/os-release ]]; then
  sed -i 's/Armbian-unofficial/Armbian/g' /etc/os-release
fi

# ============================================================================
# CLEANUP
# ============================================================================
echo "[customize-image] cleaning up"

# Mask noisy console setup units on headless images
systemctl mask console-setup.service || true
systemctl mask keyboard-setup.service || true

# Clean apt caches to keep image small and silence Armbian warnings about non-empty apt dirs
apt-get -y autoremove --purge || true
apt-get clean || true
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /var/cache/apt/* || true

echo "[customize-image] done"

#!/usr/bin/env bash
set -euo pipefail

# This script runs inside the Armbian chroot during image creation.
# It installs and configures evcc, cockpit, and caddy in a single consolidated script.

echo "[customize-image] starting"

# Load environment variables
echo "[customize-image] loading environment variables"

# Load parameters injected by outer build script
ENV_FILE="/evcc-image.env"
if [[ -f /userpatches/evcc-image.env ]]; then
  cp /userpatches/evcc-image.env "$ENV_FILE"
elif [[ -f /etc/evcc-image.env ]]; then
  cp /etc/evcc-image.env "$ENV_FILE"
fi

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# Set defaults
export EVCC_CHANNEL=${EVCC_CHANNEL:-stable}
export EVCC_HOSTNAME=${EVCC_HOSTNAME:-evcc}
export TIMEZONE=${TIMEZONE:-Europe/Berlin}
export DEBIAN_FRONTEND=noninteractive

echo "[customize-image] hostname=$EVCC_HOSTNAME channel=$EVCC_CHANNEL tz=$TIMEZONE"

# ============================================================================
# SYSTEM SETUP
# ============================================================================
echo "[customize-image] setting up system"

# Update system packages
apt-get update
apt-get -y full-upgrade

# Install base networking utils and mdns (avahi)
apt-get install -y --no-install-recommends \
  curl ca-certificates gnupg apt-transport-https \
  avahi-daemon avahi-utils libnss-mdns \
  sudo

# Set timezone
apt-get install -y --no-install-recommends tzdata
echo "$TIMEZONE" >/etc/timezone
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true

# Set hostname and mdns
echo "$EVCC_HOSTNAME" > /etc/hostname
sed -i "s/127.0.1.1\s\+.*/127.0.1.1\t$EVCC_HOSTNAME/" /etc/hosts || true

# SSH hardening (Armbian/Debian Bookworm): use drop-in to override defaults
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

# Create admin user with initial password and require password change on first login
if ! id -u admin >/dev/null 2>&1; then
  useradd -m -s /bin/bash admin
fi
echo 'admin:admin' | chpasswd
chage -d 0 admin || true
usermod -aG sudo admin || true
usermod -s /bin/bash admin || true

# Ensure admin home directory has correct ownership
chown admin:admin /home/admin

# Enable mDNS service
systemctl enable avahi-daemon || true

# Ensure root home exists for Cockpit terminal (normally present)
test -d /root || mkdir -p /root
chown -R root:root /root

# ============================================================================
# EVCC SETUP
# ============================================================================
echo "[customize-image] setting up evcc"

# Install evcc via APT repository per docs
if [[ "$EVCC_CHANNEL" == "unstable" ]]; then
  curl -1sLf 'https://dl.evcc.io/public/evcc/unstable/setup.deb.sh' | bash -E
else
  curl -1sLf 'https://dl.evcc.io/public/evcc/stable/setup.deb.sh' | bash -E
fi

apt-get update
apt-get install -y evcc

# Pre-generate minimal config if missing
if [[ ! -f /etc/evcc.yaml ]]; then
  cat >/etc/evcc.yaml <<YAML
network:
  schema: https
  host: ${EVCC_HOSTNAME}.local
  port: 80
YAML
fi

# Enable evcc service
systemctl enable evcc || true

# ============================================================================
# COCKPIT SETUP
# ============================================================================
echo "[customize-image] setting up cockpit"

# Install Cockpit and related packages
apt-get install -y --no-install-recommends \
  cockpit cockpit-pcp \
  packagekit cockpit-packagekit \
  cockpit-networkmanager network-manager \
  hostapd dnsmasq

# Cockpit configuration
mkdir -p /etc/cockpit
cat >/etc/cockpit/cockpit.conf <<'COCKPITCONF'
[WebService]
LoginTo = false
LoginTitle = "evcc"
COCKPITCONF

# Configure dnsmasq to avoid conflicts with NetworkManager
cat >/etc/dnsmasq.conf <<'DNSMASQ'
# Listen only on specific interfaces to avoid conflicts
bind-interfaces
# Don't read /etc/hosts
no-hosts
# Don't poll /etc/resolv.conf
no-poll
# Disable DHCP by default (NetworkManager handles this)
no-dhcp-interface=
DNSMASQ

# Disable dnsmasq by default - it will be enabled by wifi-connect when needed
systemctl disable dnsmasq || true

# Enable services
systemctl enable cockpit.socket || true
systemctl enable packagekit || true

# ============================================================================
# WIFI CONNECT SETUP
# ============================================================================
echo "[customize-image] setting up wifi connect"

# Install WiFi Connect manually (adapted from official raspbian-install.sh)

# Get latest release info and download WiFi Connect for ARM64
RELEASE_URL="https://api.github.com/repos/balena-os/wifi-connect/releases/latest"
WFC_BINARY_URL=$(curl -s "$RELEASE_URL" | grep "browser_download_url.*aarch64-unknown-linux-gnu\.tar\.gz" | cut -d'"' -f4)
WFC_UI_URL=$(curl -s "$RELEASE_URL" | grep "browser_download_url.*wifi-connect-ui\.tar\.gz" | cut -d'"' -f4)

if [[ -z "$WFC_BINARY_URL" || -z "$WFC_UI_URL" ]]; then
  echo "[customize-image] failed to get WiFi Connect download URLs"
  exit 1
fi

# Download and extract WiFi Connect binary
cd /tmp
curl -Ls "$WFC_BINARY_URL" | tar -xz
mv wifi-connect /usr/local/sbin/
chmod +x /usr/local/sbin/wifi-connect

# Download and extract UI assets
mkdir -p /usr/local/share/wifi-connect
curl -Ls "$WFC_UI_URL" | tar -xz -C /usr/local/share/wifi-connect/
# Fix permissions on UI assets
chmod -R 755 /usr/local/share/wifi-connect/

# Clean up
rm -rf /tmp/wifi-connect* || true

# Create network connectivity check script
cat >/usr/local/bin/check-network-connectivity <<'NETCHECK'
#!/bin/bash
# Check if we have an active network connection (ethernet or wifi)

# Check if NetworkManager is running
if ! systemctl is-active --quiet NetworkManager; then
  exit 1
fi

# Check for connected ethernet or wifi devices (more reliable than connection state)
CONNECTED_DEVICES=$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | grep -E ':(ethernet|wifi):connected$' | wc -l)

# If we have at least one connected ethernet or wifi device, we're connected
if [ "$CONNECTED_DEVICES" -gt 0 ]; then
  exit 0
else
  exit 1
fi
NETCHECK

chmod +x /usr/local/bin/check-network-connectivity

# Create WiFi Connect wrapper script
cat >/usr/local/bin/wifi-connect-wrapper <<'WRAPPER'
#!/bin/bash
# WiFi Connect wrapper that handles network detection logic

echo "WiFi Connect: Checking network connectivity..."

# Check if we have network connectivity
if /usr/local/bin/check-network-connectivity; then
    echo "WiFi Connect: Network already connected, skipping WiFi Connect setup"
    # Ensure evcc is running when network is available
    systemctl is-active --quiet evcc || systemctl start evcc
    # Create skip file to prevent future attempts until removed
    mkdir -p /var/lib/wifi-connect
    touch /var/lib/wifi-connect/skip
    exit 0
fi

echo "WiFi Connect: No network detected, starting WiFi Connect portal..."

# Remove skip file if it exists
rm -f /var/lib/wifi-connect/skip

# Stop evcc to free up port 80 for WiFi Connect portal
echo "WiFi Connect: Stopping evcc to free up port 80..."
systemctl stop evcc

# Start WiFi Connect portal
echo "WiFi Connect: Starting captive portal on evcc-setup network..."
/usr/local/sbin/wifi-connect --portal-ssid evcc-setup --ui-directory /usr/local/share/wifi-connect --activity-timeout 300 &
WIFI_PID=$!

# Wait for WiFi Connect to exit (when user configures WiFi)
wait $WIFI_PID
WIFI_EXIT_CODE=$?

echo "WiFi Connect: Portal exited with code $WIFI_EXIT_CODE"

# Start evcc again after WiFi setup is complete
echo "WiFi Connect: Restarting evcc..."
systemctl start evcc

exit $WIFI_EXIT_CODE
WRAPPER

chmod +x /usr/local/bin/wifi-connect-wrapper

# Create WiFi Connect cleanup script
cat >/usr/local/bin/wifi-connect-cleanup <<'CLEANUP'
#!/bin/bash
# WiFi Connect cleanup script

echo "WiFi Connect: Cleaning up..."

# Kill any remaining WiFi Connect processes
pkill -f wifi-connect || true

# Stop dnsmasq if it's running for WiFi Connect
pkill -f "dnsmasq.*evcc-setup" || true

# Clean up WiFi interface - disconnect from AP mode
nmcli connection down evcc-setup 2>/dev/null || true
nmcli connection delete evcc-setup 2>/dev/null || true

# Reset WiFi interface
ip link set wlan0 down 2>/dev/null || true
sleep 1
ip link set wlan0 up 2>/dev/null || true

echo "WiFi Connect: Cleanup completed"
CLEANUP

chmod +x /usr/local/bin/wifi-connect-cleanup

# Create WiFi Connect systemd service
cat >/etc/systemd/system/wifi-connect.service <<'WIFICONNECT'
[Unit]
Description=WiFi Connect
Documentation=https://github.com/balena-os/wifi-connect
Wants=NetworkManager.service
After=NetworkManager.service
ConditionPathExists=!/var/lib/wifi-connect/skip

[Service]
Type=oneshot
User=root
# Use a wrapper script that handles the network check logic
ExecStart=/usr/local/bin/wifi-connect-wrapper
ExecStop=/usr/local/bin/wifi-connect-cleanup
RemainAfterExit=yes
TimeoutStartSec=300
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
WIFICONNECT

# Create a timer to periodically check network connectivity and restart wifi-connect if needed
cat >/etc/systemd/system/wifi-connect-check.service <<'WIFICHECK'
[Unit]
Description=WiFi Connect Network Check
Documentation=https://github.com/balena-os/wifi-connect
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wifi-connect-check
# Don't fail if NetworkManager isn't ready yet
SuccessExitStatus=0 1
WIFICHECK

cat >/etc/systemd/system/wifi-connect-check.timer <<'WIFITIMER'
[Unit]
Description=WiFi Connect Network Check Timer
Requires=wifi-connect-check.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
WIFITIMER

# Create the check script that the timer runs
cat >/usr/local/bin/wifi-connect-check <<'WIFICHECKSCRIPT'
#!/bin/bash
# Check network connectivity and manage wifi-connect service accordingly

if ! /usr/local/bin/check-network-connectivity; then
  # No network connection, ensure wifi-connect is running
  if ! systemctl is-active --quiet wifi-connect; then
    # Remove skip file if it exists and restart service
    rm -f /var/lib/wifi-connect/skip
    systemctl restart wifi-connect
  fi
else
  # Network is connected, stop wifi-connect if running
  if systemctl is-active --quiet wifi-connect; then
    systemctl stop wifi-connect
  fi
fi
WIFICHECKSCRIPT

chmod +x /usr/local/bin/wifi-connect-check

# Create directory for wifi-connect state
mkdir -p /var/lib/wifi-connect

# Enable the services
systemctl enable wifi-connect || true
systemctl enable wifi-connect-check.timer || true

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
}

# HTTPS on 443 with Caddy internal TLS
${EVCC_HOSTNAME}.local:443 {
  tls internal
  encode zstd gzip
  log
  reverse_proxy 127.0.0.1:80
}

CADDY

# Enable Caddy service
systemctl enable caddy || true

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
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

# Install base utils and mdns (avahi)
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
  useradd -M -s /bin/bash admin  # -M to skip home directory creation
fi
echo 'admin:admin' | chpasswd
chage -d 0 admin || true
usermod -aG sudo,netdev admin || true

# Create home directory on first boot (since it doesn't persist during build)
cat >/etc/systemd/system/admin-home-setup.service <<'EOF'
[Unit]
Description=Create admin home directory on first boot
ConditionPathExists=!/home/admin
Before=getty@tty1.service ssh.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'mkdir -p /home/admin && cp -r /etc/skel/. /home/admin/ 2>/dev/null || true && chown -R admin:admin /home/admin && chmod 755 /home/admin'

[Install]
WantedBy=multi-user.target
EOF

systemctl enable admin-home-setup.service

# Enable mDNS service
systemctl enable avahi-daemon || true

# Ensure root home exists for Cockpit terminal (normally present)
test -d /root || mkdir -p /root
chown -R root:root /root

# ============================================================================
# WIFI-CONNECT SETUP
# ============================================================================
echo "[customize-image] setting up wifi-connect for wifi configuration"

# Install dnsmasq (required by wifi-connect for DHCP)
apt-get install -y --no-install-recommends dnsmasq
systemctl disable dnsmasq.service || true

# Download and install wifi-connect
WIFI_CONNECT_VERSION=$(curl -s https://api.github.com/repos/balena-os/wifi-connect/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
echo "[customize-image] Installing wifi-connect version: $WIFI_CONNECT_VERSION"

# Determine architecture
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
  armhf)
    WIFI_CONNECT_ARCH="armv7-unknown-linux-gnueabihf"
    ;;
  arm64|aarch64)
    WIFI_CONNECT_ARCH="aarch64-unknown-linux-gnu"
    ;;
  *)
    echo "[customize-image] Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

# Download and extract wifi-connect
curl -L -o /tmp/wifi-connect.tar.gz \
  "https://github.com/balena-os/wifi-connect/releases/download/$WIFI_CONNECT_VERSION/wifi-connect-$WIFI_CONNECT_ARCH.tar.gz"
tar -xzf /tmp/wifi-connect.tar.gz -C /tmp/
mv /tmp/wifi-connect /usr/local/sbin/
chmod +x /usr/local/sbin/wifi-connect
rm -f /tmp/wifi-connect.tar.gz

# Create custom UI with compact HTML
mkdir -p /usr/local/share/wifi-connect-ui
cat >/usr/local/share/wifi-connect-ui/index.html <<'HTML'
<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1"><title>WiFi Setup - evcc</title><style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;padding:20px;background:#f5f5f5;min-height:100vh}
.container{max-width:400px;margin:0 auto;background:#fff;border-radius:12px;padding:24px;box-shadow:0 2px 12px rgba(0,0,0,0.08)}
.logo{text-align:center;margin-bottom:24px}
h1{color:#1a1a1a;margin-bottom:8px;font-size:24px;font-weight:600}
.subtitle{color:#666;margin-bottom:24px;font-size:14px}
.network-list{margin:20px 0}
.network{padding:16px;border:1px solid #e0e0e0;margin:8px 0;cursor:pointer;border-radius:8px;display:flex;justify-content:space-between;align-items:center;transition:all 0.2s}
.network:hover{background:#f8f9fa;border-color:#0ea5e9}
.network-name{font-weight:500;color:#333}
.signal{font-size:12px;color:#888}
input{width:100%;padding:12px 16px;margin:12px 0;border:1px solid #e0e0e0;border-radius:8px;font-size:16px;transition:border-color 0.2s}
input:focus{outline:none;border-color:#0ea5e9}
button{background:#0ea5e9;color:#fff;border:none;padding:12px 24px;cursor:pointer;border-radius:8px;width:100%;font-size:16px;font-weight:500;transition:background 0.2s}
button:hover:not(:disabled){background:#0284c7}
button:disabled{background:#cbd5e1;cursor:not-allowed}
.secondary-btn{background:#64748b;margin-top:8px}
.secondary-btn:hover{background:#475569}
.status{padding:12px 16px;margin:16px 0;border-radius:8px;text-align:center;font-size:14px}
.status.info{background:#dbeafe;color:#1e40af;border:1px solid #93c5fd}
.status.success{background:#dcfce7;color:#166534;border:1px solid #86efac}
.status.error{background:#fee2e2;color:#991b1b;border:1px solid #fca5a5}
.hidden{display:none}
.loading{text-align:center;padding:32px;color:#666}
.spinner{border:3px solid #f3f4f6;border-top:3px solid #0ea5e9;border-radius:50%;width:24px;height:24px;animation:spin 1s linear infinite;margin:0 auto 16px}
@keyframes spin{0%{transform:rotate(0deg)}100%{transform:rotate(360deg)}}
</style></head><body>
<div class="container">
<div class="logo"><h1>evcc WiFi Setup</h1><div class="subtitle">Select your network to get started</div></div>
<div id="status" class="status hidden"></div>
<div id="network-list"><div class="loading"><div class="spinner"></div>Scanning for networks...</div></div>
<div id="connect-form" class="hidden">
<h2 style="margin-bottom:16px;font-size:18px">Connect to <span id="selected-network"></span></h2>
<input type="password" id="password" placeholder="Enter WiFi password" autocomplete="off">
<button id="connect-btn" onclick="connect()">Connect</button>
<button class="secondary-btn" onclick="showNetworks()">← Back to networks</button>
</div>
</div>
<script>
let selectedSSID='',networks=[];
function loadNetworks(){fetch('/networks').then(r=>r.json()).then(data=>{networks=data;displayNetworks()}).catch(err=>{document.getElementById('network-list').innerHTML='<div class="status error">Failed to load networks. Please refresh the page.</div><button onclick="location.reload()">Refresh</button>'})}
function displayNetworks(){if(networks.length===0){document.getElementById('network-list').innerHTML='<div class="status info">No WiFi networks found</div><button onclick="loadNetworks()">Scan Again</button>';return}
const html='<div class="network-list">'+networks.map(n=>{const signal=n.signal?Math.min(100,Math.max(0,(n.signal+100)*2))+'%':'';return'<div class="network" onclick="selectNetwork(\''+n.ssid.replace(/'/g,"\\'")+'\')">'+'<span class="network-name">'+n.ssid+'</span>'+'<span class="signal">'+signal+'</span>'+'</div>'}).join('')+'</div>';document.getElementById('network-list').innerHTML=html}
function selectNetwork(ssid){selectedSSID=ssid;document.getElementById('selected-network').textContent=ssid;document.getElementById('network-list').classList.add('hidden');document.getElementById('connect-form').classList.remove('hidden');document.getElementById('status').classList.add('hidden');document.getElementById('password').value='';document.getElementById('password').focus()}
function showNetworks(){document.getElementById('connect-form').classList.add('hidden');document.getElementById('network-list').classList.remove('hidden');document.getElementById('status').classList.add('hidden')}
function showStatus(message,type){const status=document.getElementById('status');status.textContent=message;status.className='status '+type;status.classList.remove('hidden')}
function connect(){const password=document.getElementById('password').value;const button=document.getElementById('connect-btn');if(!password){showStatus('Please enter a password','error');return}
button.disabled=true;button.textContent='Connecting...';showStatus('Connecting to '+selectedSSID+'...','info');
fetch('/connect',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ssid:selectedSSID,identity:'',passphrase:password})})
.then(r=>{if(r.ok){showStatus('Successfully connected! You can close this window.','success');setTimeout(()=>{document.body.innerHTML='<div class="container"><div class="status success">Connected to '+selectedSSID+'</div><p style="text-align:center;margin-top:20px">You can now close this window and access evcc at <strong>https://evcc.local</strong></p></div>'},2000)}else{throw new Error('Connection failed')}})
.catch(err=>{showStatus('Failed to connect. Please check the password and try again.','error');button.disabled=false;button.textContent='Connect'})}
document.addEventListener('DOMContentLoaded',()=>{document.getElementById('password').addEventListener('keypress',(e)=>{if(e.key==='Enter')connect()});loadNetworks();setInterval(()=>{if(!document.getElementById('network-list').classList.contains('hidden')){loadNetworks()}},10000)});
</script></body></html>
HTML

# Create systemd service for wifi-connect
cat >/etc/systemd/system/wifi-connect.service <<'WIFISERVICE'
[Unit]
Description=Balena WiFi Connect
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=simple
Restart=on-failure
RestartSec=5
ExecStart=/usr/local/sbin/wifi-connect --portal-ssid "evcc-setup" --ui-directory /usr/local/share/wifi-connect-ui
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
WIFISERVICE

# Enable wifi-connect service
systemctl enable wifi-connect.service || true


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
YAML
fi

# Enable evcc service
systemctl enable evcc || true

# ============================================================================
# COCKPIT SETUP
# ============================================================================
echo "[customize-image] setting up cockpit"

# Add AllStarLink repository for cockpit-wifimanager
curl -L -o /tmp/asl-apt-repos.deb12_all.deb \
  "https://repo.allstarlink.org/public/asl-apt-repos.deb12_all.deb"
dpkg -i /tmp/asl-apt-repos.deb12_all.deb || apt-get install -f -y
apt-get update
rm -f /tmp/asl-apt-repos.deb12_all.deb

# Install Cockpit and related packages
apt-get install -y --no-install-recommends \
  cockpit cockpit-pcp \
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
}

# HTTPS on 443 with Caddy internal TLS
${EVCC_HOSTNAME}.local:443 {
  tls internal
  encode zstd gzip
  log
  reverse_proxy 127.0.0.1:7070
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
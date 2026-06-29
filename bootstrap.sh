#!/bin/bash
set -e

GH_OWNER="kadi1m"
GH_REPO="autobuilder-worker-v2"
TARGET_DIR="/opt/worker-v2"
SERVICE_NAME="worker-v2-update"

if [ "$EUID" -ne 0 ]; then
  echo "❌ This setup script must be run with administrative privileges. Please use 'sudo bash'."
  exit 1
fi

if [ -z "$1" ]; then
    echo "Usage: curl ... | sudo bash -s -- <CONTROL_PLANE_TOKEN>"
    exit 1
fi
CP_TOKEN="$1"

# Determine the user who invoked the script
if [ -n "$SUDO_USER" ]; then
    WORKER_USER="$SUDO_USER"
else
    WORKER_USER="$(whoami)"
fi
WORKER_GROUP="$(id -g -n $WORKER_USER)"
echo "👤 Configuring worker to run as user: $WORKER_USER, group: $WORKER_GROUP"

echo "🧹 HARD RESET: Cleaning up any old installations..."
systemctl stop ${SERVICE_NAME}.timer >/dev/null 2>&1 || true
systemctl disable ${SERVICE_NAME}.timer >/dev/null 2>&1 || true
systemctl stop ${SERVICE_NAME}.service >/dev/null 2>&1 || true
systemctl disable ${SERVICE_NAME}.service >/dev/null 2>&1 || true
rm -rf "$TARGET_DIR"

echo "📦 Installing system dependencies (Node.js, npm, pm2, build tools, Docker)..."
apt-get update -y || true

if ! command -v docker &> /dev/null; then
    echo "🐳 Installing Docker..."
    apt-get install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
      
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
    echo "✅ Docker is already installed."
fi

# Ensure the worker user can run docker commands without sudo
usermod -aG docker $WORKER_USER


if ! command -v npm &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs build-essential python3 python-is-python3
else
    echo "✅ Node.js/npm is already installed."
    apt-get install -y build-essential python3 python-is-python3
fi

if ! command -v pm2 &> /dev/null; then
    echo "📦 Installing PM2 globally..."
    npm install -g pm2
fi

echo "⚙️ Creating target directory structure..."
mkdir -p "$TARGET_DIR"

echo "📥 Downloading the absolute freshest deploy-worker.sh from GitHub..."
curl -sL -o "$TARGET_DIR/deploy-worker.sh" "https://raw.githubusercontent.com/$GH_OWNER/$GH_REPO/main/deploy-worker.sh"
chmod +x "$TARGET_DIR/deploy-worker.sh"
chown -R $WORKER_USER:$WORKER_GROUP "$TARGET_DIR"

echo "🔧 Fixing npm cache permissions just in case root contaminated them..."
mkdir -p /home/$WORKER_USER/.npm
chown -R $WORKER_USER:$WORKER_GROUP /home/$WORKER_USER/.npm

echo "📝 Registering systemd service..."
cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=Pull Latest Worker V2 Repo and Deploy
After=network.target

[Service]
Type=oneshot
User=$WORKER_USER
Group=$WORKER_GROUP
WorkingDirectory=$TARGET_DIR
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
Environment="HOME=/home/$WORKER_USER"
ExecStart=/bin/bash $TARGET_DIR/deploy-worker.sh "$CP_TOKEN"
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.timer
[Unit]
Description=Run worker V2 auto-update interval timer

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "🔄 Hard-reloading system configuration states..."
systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}.timer

echo "🚀 Forcing deployment script execution right now..."
systemctl start ${SERVICE_NAME}.service

echo "✨ Active provisioning complete!"

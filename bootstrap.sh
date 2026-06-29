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
systemctl stop ${SERVICE_NAME}.timer || true
systemctl disable ${SERVICE_NAME}.timer || true
rm -rf "$TARGET_DIR"

echo "📦 Installing system dependencies (Node.js, npm, pm2)..."
if ! command -v npm &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
else
    echo "✅ Node.js/npm is already installed."
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

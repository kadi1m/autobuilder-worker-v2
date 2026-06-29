#!/bin/bash
set -e

GH_OWNER="kadi1m"
GH_REPO="autobuilder-worker-v2"
CONTROL_PLANE_URL="http://192.168.1.222:3000/api/v1/nodes/register" # Update this to your production URL later
TARGET_DIR="/opt/worker-v2"

if [ -z "$1" ]; then
    echo "❌ Error: Control Plane registration token is required."
    exit 1
fi
CP_TOKEN="$1"

NODE_ID=$(hostname)
echo "🚀 Beginning worker build tasks on node: $NODE_ID"

# 1. Fetch the absolute latest source archive from the public repo main branch
echo "📥 Fetching complete fresh source bundle from GitHub..."
curl -sL -o /tmp/source.tar.gz "https://api.github.com/repos/$GH_OWNER/$GH_REPO/tarball/main"

# 2. FORCE PURGE old app state to avoid file contamination or caching bugs
echo "🧹 Wiping old installation directory to guarantee a clean state..."
rm -rf "$TARGET_DIR/app"
mkdir -p "$TARGET_DIR/app"

# 3. Extract fresh codebase
echo "📦 Extracting new codebase..."
tar -xzf /tmp/source.tar.gz -C "$TARGET_DIR/app" --strip-components=1
rm /tmp/source.tar.gz

# --- Execute App Build / Runtime Setup Here ---
cd "$TARGET_DIR/app"
echo "🛠️ Installing dependencies..."
npm install --omit=dev --verbose

# 4. Start or restart the worker process via PM2 using npx
echo "🔄 Starting/Restarting worker process with PM2..."

# If PM2 is already managing the worker, restart it. Otherwise, start fresh.
if npx pm2 describe worker-node-v2 &> /dev/null; then
  # In production, change localhost to your control plane IP
  CONTROL_PLANE_HOST="192.168.1.222:3000" npx pm2 restart worker-node-v2 --update-env
else
  CONTROL_PLANE_HOST="192.168.1.222:3000" npx pm2 start "$TARGET_DIR/app/index.js" \
    --name worker-node-v2 \
    --env production
  npx pm2 save
fi

# 5. Notify Control Plane of successful sync (Assuming you build a /register route later)
echo "📡 Announcing state to Control Plane..."
curl -X POST "$CONTROL_PLANE_URL" \
  --connect-timeout 5 \
  -H "Authorization: Bearer $CP_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"node_id\": \"$NODE_ID\", \"status\": \"active\"}" || echo "⚠️ Warning: Could not reach Control Plane at $CONTROL_PLANE_URL"

echo "✅ Node sync and clean rebuild complete."

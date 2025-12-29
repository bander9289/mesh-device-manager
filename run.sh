#!/bin/bash
# run.sh - Launch app with mesh credentials from .env file

set -e

# Load environment variables from .env if it exists
if [ -f .env ]; then
  export $(cat .env | grep -v '^#' | xargs)
  echo "✓ Loaded credentials from .env"
else
  echo "⚠️  .env file not found. Using .env.example values."
  export $(cat .env.example | grep -v '^#' | xargs)
fi

# Check that required variables are set
if [ -z "$MESH_NET_KEY" ] || [ -z "$MESH_APP_KEY" ]; then
  echo "❌ Error: MESH_NET_KEY or MESH_APP_KEY not set"
  echo "   Please check your .env file"
  exit 1
fi

echo "✓ MESH_NET_KEY: ${MESH_NET_KEY:0:8}..."
echo "✓ MESH_APP_KEY: ${MESH_APP_KEY:0:8}..."
echo ""
echo "Starting Flutter app..."

# Run flutter with credentials
flutter run \
  --dart-define=MESH_NET_KEY=$MESH_NET_KEY \
  --dart-define=MESH_APP_KEY=$MESH_APP_KEY \
  "$@"

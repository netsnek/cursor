#!/bin/bash
# Launch Cursor as a web app (PWA) in the browser.
# Uses VS Code's serve-web with Cursor branding.
set -euo pipefail

PORT="${1:-8080}"
CORS_PORT="${2:-9080}"
CURSOR_DIR="${CURSOR_DIR:-/opt/cursor}"
SCRIPTDIR="$(cd "$(dirname "$0")" && pwd)"

# Start CORS proxy for Cursor API calls (api2.cursor.sh)
CORS_PROXY="$SCRIPTDIR/cursor-cors-proxy.js"
if [ -f "$CORS_PROXY" ]; then
  # Kill any existing proxy on this port
  fuser -k "$CORS_PORT/tcp" 2>/dev/null || true
  node "$CORS_PROXY" "$CORS_PORT" &
  CORS_PID=$!
  trap "kill $CORS_PID 2>/dev/null" EXIT
fi

echo "==> Starting Cursor Web on port $PORT..."
echo "    CORS proxy on port $CORS_PORT"
echo "    Open http://localhost:$PORT in your browser"
echo "    Install as PWA: Browser menu → Install Cursor..."
echo ""

exec "$CURSOR_DIR/bin/cursor" serve-web \
  --without-connection-token \
  --accept-server-license-terms \
  --port "$PORT" \
  --host 127.0.0.1

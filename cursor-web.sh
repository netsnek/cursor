#!/bin/bash
# Launch Cursor as a web app (PWA) in the browser.
# Uses VS Code's serve-web with Cursor branding.
set -euo pipefail

PORT="${1:-8080}"
CURSOR_DIR="${CURSOR_DIR:-/opt/cursor}"

echo "==> Starting Cursor Web on port $PORT..."
echo "    Open http://localhost:$PORT in your browser"
echo "    Install as PWA: Browser menu → Install Cursor..."
echo ""

exec "$CURSOR_DIR/bin/cursor" serve-web \
  --without-connection-token \
  --accept-server-license-terms \
  --port "$PORT" \
  --host 127.0.0.1

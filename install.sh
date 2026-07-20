#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Lumen Install ==="
echo "Installing Crystal dependencies..."
shards install
echo "Building application..."
shards build
echo ""
echo "Install complete. Binary: bin/lumen"
echo ""
echo "To run:"
echo "  ./bin/lumen"
echo ""
echo "The server auto-creates the database and seeds demo data on first boot."
echo "Demo login: cenius@cenius.ai / cenius"

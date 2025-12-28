#!/bin/bash
# Install netv systemd service
# Prerequisites: uv (install time only), install-letsencrypt.sh
#
# Usage: sudo ./install-netv.sh [--port PORT]
#   --port PORT  Port to listen on (default: 8000)
set -e

IPTV_DIR="$(cd "$(dirname "$0")/.." && pwd)"
USER="${SUDO_USER:-$USER}"
PORT=8000

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --port)
            PORT="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: sudo $0 [--port PORT]"
            exit 1
            ;;
    esac
done

# Validate
if [ "$USER" = "root" ]; then
    echo "Error: Run with sudo, not as root directly"
    echo "Usage: sudo $0 [--port PORT]"
    exit 1
fi

# Find uv in user's environment (only needed at install time)
UV_PATH=$(su - "$USER" -c "which uv" 2>/dev/null)
if [ -z "$UV_PATH" ]; then
    echo "Error: uv not found for user $USER. Install with:"
    echo "  curl -LsSf https://astral.sh/uv/install.sh | sh"
    echo "See: https://docs.astral.sh/uv/"
    exit 1
fi

echo "=== Syncing dependencies ==="
su - "$USER" -c "cd '$IPTV_DIR' && '$UV_PATH' sync"

if [ ! -d /etc/letsencrypt/live ]; then
    echo "Warning: Let's Encrypt not configured. Run install-letsencrypt.sh first for HTTPS."
    echo "Continuing with HTTP-only setup..."
    HTTPS_FLAG=""
else
    HTTPS_FLAG="--https"
fi

echo "=== Installing netv for user: $USER (port $PORT) ==="

echo "=== Adding $USER to ssl-cert group ==="
sudo usermod -aG ssl-cert "$USER"

echo "=== Installing netv systemd service ==="

cat <<EOF | sudo tee /etc/systemd/system/netv.service
[Unit]
Description=NetV IPTV Server
After=network.target

[Service]
Type=simple
User=$USER
Group=ssl-cert
WorkingDirectory=$IPTV_DIR
ExecStart=$IPTV_DIR/.venv/bin/python ./main.py --port $PORT $HTTPS_FLAG
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable netv
sudo systemctl start netv

if [ -n "$HTTPS_FLAG" ]; then
    echo "=== Installing certbot deploy hook (restart netv on renewal) ==="
    cat <<'EOF' | sudo tee /etc/letsencrypt/renewal-hooks/deploy/netv
#!/bin/bash
# Restart netv after cert renewal
systemctl restart netv
EOF
    sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/netv
fi

echo ""
echo "=== Done ==="
echo ""
echo "Commands:"
echo "  sudo systemctl status netv     # Check status"
echo "  sudo systemctl restart netv    # Restart after code changes"
echo "  journalctl -u netv -f          # View logs"

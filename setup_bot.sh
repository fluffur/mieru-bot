#!/usr/bin/env bash
set -euo pipefail

echo
echo "Mieru Telegram Bot Setup Script"
echo

REPO_URL="https://github.com/fluffur/mieru-bot.git"
INSTALL_DIR="/opt/mieru-bot"

get_input() {
local prompt="${1:-}"
local default="${2:-}"
local value

```
if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " value
    value=${value:-$default}
else
    read -rp "$prompt: " value
fi

echo "$value"
```

}

get_yes_no() {
local prompt="$1"
local default="$2"

```
while true; do
    local answer
    answer=$(get_input "$prompt" "$default")
    answer=${answer,,}

    case "$answer" in
        y|yes) return 0 ;;
        n|no) return 1 ;;
        *) echo "Please answer y or n." ;;
    esac
done
```

}

validate_port_range() {
local range="$1"

```
[[ "$range" =~ ^[0-9]+-[0-9]+$ ]] || return 1

local start=${range%-*}
local end=${range#*-}

(( start >= 1 )) || return 1
(( end <= 65535 )) || return 1
(( start <= end )) || return 1

return 0
```

}

if ! command -v git >/dev/null 2>&1; then
echo "Installing git..."
apt-get update
apt-get install -y git
fi

if ! command -v python3 >/dev/null 2>&1; then
echo "Installing python3..."
apt-get update
apt-get install -y python3 python3-pip python3-venv
fi

if [[ ! -d "$INSTALL_DIR/.git" ]]; then
echo "Cloning repository..."
rm -rf "$INSTALL_DIR"
git clone "$REPO_URL" "$INSTALL_DIR"
else
echo "Updating repository..."
git -C "$INSTALL_DIR" pull
fi

cd "$INSTALL_DIR"

BOT_TOKEN=""
while [[ -z "${BOT_TOKEN:-}" ]]; do
BOT_TOKEN=$(get_input "Enter your Telegram bot token (from BotFather)" "")
done

ADMIN_IDS=""
while [[ -z "${ADMIN_IDS:-}" ]]; do
ADMIN_IDS=$(get_input "Enter admin Telegram user IDs (space-separated)" "")
done

PORT_RANGE=""
while [[ -z "${PORT_RANGE:-}" ]]; do
PORT_RANGE=$(get_input "Enter the Mieru port range (start-end)" "9000-9010")

```
if ! validate_port_range "$PORT_RANGE"; then
    echo "Invalid range."
    PORT_RANGE=""
fi
```

done

cat > .env <<EOF
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
ADMIN_IDS=${ADMIN_IDS}
PORT_RANGE=${PORT_RANGE}
EOF

echo "Creating virtual environment..."

if [[ ! -d .venv ]]; then
python3 -m venv .venv
fi

.venv/bin/pip install --upgrade pip
.venv/bin/pip install --no-cache-dir -r requirements.txt

SERVICE_NAME="mieru_bot"

cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=Mieru Telegram Bot
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/.venv/bin/python3 ${INSTALL_DIR}/main.py
EnvironmentFile=${INSTALL_DIR}/.env
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}

echo
echo "Installation completed"
echo
echo "Service status:"
systemctl --no-pager status ${SERVICE_NAME} || true

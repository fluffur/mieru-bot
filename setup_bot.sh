#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo "     Mieru Telegram Bot Setup Script"
echo "=========================================="

get_input() {
    local prompt=$1
    local default=$2
    local value

    if [[ -n "$default" ]]; then
        read -rp "$prompt [$default]: " value
        value=${value:-$default}
    else
        read -rp "$prompt: " value
    fi

    echo "$value"
}

get_yes_no() {
    local prompt=$1
    local default=$2
    local answer

    while true; do
        answer=$(get_input "$prompt" "$default")
        answer=${answer,,}
        case "$answer" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

validate_port_range() {
    local range=$1
    if [[ ! "$range" =~ ^[0-9]+-[0-9]+$ ]]; then
        return 1
    fi

    local start=${range%-*}
    local end=${range#*-}
    if (( start < 1 || end > 65535 || start > end )); then
        return 1
    fi

    return 0
}

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required. Install Python 3 and try again." >&2
    exit 1
fi

if ! command -v pip3 >/dev/null 2>&1; then
    echo "Error: pip3 is required. Install pip3 and try again." >&2
    exit 1
fi

BOT_TOKEN=""
while [[ -z "$BOT_TOKEN" ]]; do
    BOT_TOKEN=$(get_input "Enter your Telegram bot token (from BotFather)" "")
    if [[ -z "$BOT_TOKEN" ]]; then
        echo "Bot token cannot be empty. Get it from BotFather in Telegram." >&2
    fi
done

ADMIN_IDS=""
while [[ -z "$ADMIN_IDS" ]]; do
    ADMIN_IDS=$(get_input "Enter admin Telegram user IDs (space-separated)" "")
    if [[ -z "$ADMIN_IDS" ]]; then
        echo "At least one admin ID is required. Find your numeric Telegram ID using @userinfobot or similar." >&2
    fi
done

PORT_RANGE=""
while [[ -z "$PORT_RANGE" ]]; do
    PORT_RANGE=$(get_input "Enter the Mieru port range (start-end)" "9000-9010")
    if ! validate_port_range "$PORT_RANGE"; then
        echo "Invalid port range. Use the format start-end, for example 9000-9010." >&2
        PORT_RANGE=""
    fi
done

cat > .env <<EOF
TELEGRAM_BOT_TOKEN=${BOT_TOKEN}
ADMIN_IDS=${ADMIN_IDS}
PORT_RANGE=${PORT_RANGE}
EOF

echo "Created .env with the following values:"
echo "  TELEGRAM_BOT_TOKEN=***"
echo "  ADMIN_IDS=${ADMIN_IDS}"
echo "  PORT_RANGE=${PORT_RANGE}"

if [[ ! -f requirements.txt ]]; then
    echo "Error: requirements.txt not found in the current directory." >&2
    exit 1
fi

if [[ ! -d .venv ]]; then
    echo "Creating Python virtual environment in .venv..."
    python3 -m venv .venv
fi

echo "Installing dependencies..."
.venv/bin/pip install --upgrade pip
.venv/bin/pip install --no-cache-dir -r requirements.txt

PROJECT_DIR="$(pwd)"
SERVICE_NAME="mieru_bot"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SERVICE_USER="${SUDO_USER:-$(whoami)}"
SERVICE_STARTED=false

if get_yes_no "Create and enable a systemd service for the bot? (y/n)" "y"; then
    SERVICE_USER=$(get_input "Run service as user" "$SERVICE_USER")

    SERVICE_CONTENT="[Unit]
Description=Mieru Telegram Bot
After=network.target

[Service]
Type=simple
WorkingDirectory=${PROJECT_DIR}
ExecStart=${PROJECT_DIR}/.venv/bin/python3 ${PROJECT_DIR}/main.py
EnvironmentFile=${PROJECT_DIR}/.env
Restart=always
RestartSec=5s
User=${SERVICE_USER}

[Install]
WantedBy=multi-user.target
"

    if [[ -f "$SERVICE_FILE" ]]; then
        if get_yes_no "Service file ${SERVICE_FILE} already exists. Overwrite? (y/n)" "n"; then
            :
        else
            echo "Skipping service creation." >&2
            SERVICE_FILE=""
        fi
    fi

    if [[ -n "$SERVICE_FILE" ]]; then
        if [[ $EUID -ne 0 ]]; then
            if ! command -v sudo >/dev/null 2>&1; then
                echo "Error: root permission or sudo is required to write ${SERVICE_FILE}." >&2
                exit 1
            fi
            printf '%s
' "$SERVICE_CONTENT" | sudo tee "$SERVICE_FILE" >/dev/null
        else
            printf '%s
' "$SERVICE_CONTENT" > "$SERVICE_FILE"
        fi

        if get_yes_no "Reload systemd and enable/start the service now? (y/n)" "y"; then
            if [[ $EUID -ne 0 ]]; then
                sudo systemctl daemon-reload
                sudo systemctl enable --now "$SERVICE_NAME"
            else
                systemctl daemon-reload
                systemctl enable --now "$SERVICE_NAME"
            fi
            SERVICE_STARTED=true
            echo "Service ${SERVICE_NAME} created and started."
        else
            if [[ $EUID -ne 0 ]]; then
                echo "Run the following commands to activate the service:"
                echo "  sudo systemctl daemon-reload"
                echo "  sudo systemctl enable --now ${SERVICE_NAME}"
            else
                echo "Run the following commands to activate the service:"
                echo "  systemctl daemon-reload"
                echo "  systemctl enable --now ${SERVICE_NAME}"
            fi
        fi
    fi
fi

echo
if [[ "$SERVICE_STARTED" == "true" ]]; then
    echo "Setup complete. Bot is running as systemd service ${SERVICE_NAME}."
else
    echo "Setup complete. Configuration and dependencies are ready."
fi

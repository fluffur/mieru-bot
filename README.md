# Mieru Telegram Bot

Telegram bot for managing [mieru](https://github.com/enfein/mieru) users

## Setup

Run the setup script:

```bash
curl -fsSL https://raw.githubusercontent.com/flurffur/mieru-bot/main/setup_bot.sh | bash
```

The script will ask for:

- Telegram bot token from [@BotFather](https://t.me/BotFather)
- admin Telegram user IDs (can be obtained from [@userinfobot](https://t.me/userinfobot))
- Mieru port range (default `9000-9010`)

It will write `.env`, install dependencies into `.venv`, and optionally create and start a `systemd` service.

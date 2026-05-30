#!/usr/bin/env python3
import io
import json
import os
import secrets
import string
import subprocess
import sys
import tempfile
import urllib.request

from aiogram import Bot, Dispatcher, types
from aiogram.filters import Command
from aiogram.types import InputFile

BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
ADMIN_IDS = {
    int(item)
    for item in os.getenv("ADMIN_IDS", "").split()
    if item.strip().isdigit()
}
PORT_RANGE = os.getenv("PORT_RANGE", "9000-9010")
try:
    PORT_START, PORT_END = [int(x) for x in PORT_RANGE.split("-", 1)]
    if PORT_START < 1 or PORT_END > 65535 or PORT_START > PORT_END:
        raise ValueError
except ValueError:
    print("PORT_RANGE должен быть в виде start-end, например 9000-9010", file=sys.stderr)
    sys.exit(1)

if not BOT_TOKEN:
    print("TELEGRAM_BOT_TOKEN не задан", file=sys.stderr)
    sys.exit(1)

bot = Bot(token=BOT_TOKEN, parse_mode="HTML")
dp = Dispatcher()


def run_command(command, input_data=None) -> str:
    result = subprocess.run(
        command,
        input=input_data,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"Команда {' '.join(command)} завершилась с ошибкой: {result.stderr.strip()}"
        )
    return result.stdout


def ensure_admin(user_id: int) -> bool:
    return not ADMIN_IDS or user_id in ADMIN_IDS


def get_public_ip() -> str:
    try:
        with urllib.request.urlopen("https://api.ipify.org", timeout=10) as response:
            return response.read().decode("utf-8").strip()
    except Exception as exc:
        raise RuntimeError(f"Не удалось определить IP: {exc}")


def load_current_config() -> dict:
    output = run_command(["mita", "describe", "config"])
    try:
        return json.loads(output)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Не удалось разобрать JSON конфига: {exc}")


def save_config(config: dict) -> None:
    config_json = json.dumps(config, ensure_ascii=False)
    with tempfile.NamedTemporaryFile(mode="w+", suffix=".json", delete=False) as temp_file:
        temp_file.write(config_json)
        temp_path = temp_file.name

    try:
        run_command(["mita", "apply", "config", temp_path])
    finally:
        try:
            os.unlink(temp_path)
        except OSError:
            pass


def build_client_config(server_ip: str, username: str, password: str, port_start: int) -> dict:
    return {
        "log": {"level": "info"},
        "dns": {
            "servers": [
                {"tag": "google", "address": "8.8.8.8"},
                {"tag": "local", "address": "1.1.1.1", "detour": "direct"},
            ]
        },
        "outbounds": [
            {
                "type": "mieru",
                "tag": "mieru-out",
                "server": server_ip,
                "server_port": port_start,
                "transport": "TCP",
                "username": username,
                "password": password,
                "multiplexing": "MULTIPLEXING_LOW",
            },
            {"type": "direct", "tag": "direct"},
        ],
        "route": {"final": "mieru-out"},
    }


def build_mieru_link(server_ip: str, username: str, password: str, port_start: int, port_end: int) -> str:
    return (
        f"mierus://{username}:{password}@{server_ip}:{port_start}"
        f"?transport=TCP&multiplexing=MULTIPLEXING_LOW&server_ports={port_start}-{port_end}"
    )


def generate_password(length: int = 24) -> str:
    alphabet = string.ascii_letters + string.digits
    return ''.join(secrets.choice(alphabet) for _ in range(length))


@dp.message(Command(commands=["start", "help"]))
async def command_help(message: types.Message) -> None:
    text = (
        "Команды бота:\n"
        "/add &lt;username&gt; — добавить пользователя и получить JSON\n"
        "/del &lt;username&gt; — удалить пользователя\n"
        "/list — показать список пользователей\n"
        "/help — это сообщение\n"
    )
    await message.answer(text)


@dp.message(Command(commands=["list"]))
async def command_list(message: types.Message) -> None:
    if not ensure_admin(message.from_user.id):
        await message.answer("Доступ запрещён")
        return

    try:
        config = load_current_config()
    except RuntimeError as exc:
        await message.answer(f"Ошибка: {exc}")
        return

    users = config.get("users", [])
    if not users:
        await message.answer("Список пользователей пуст")
        return

    lines = [f"{idx + 1}. {user.get('name', '<unknown>')}" for idx, user in enumerate(users)]
    await message.answer('Пользователи mita:\n' + "\n".join(lines))


@dp.message(Command(commands=["add"]))
async def command_add(message: types.Message) -> None:
    if not ensure_admin(message.from_user.id):
        await message.answer("Доступ запрещён")
        return

    parts = message.text.strip().split(maxsplit=1)
    if len(parts) < 2 or not parts[1].strip():
        await message.answer("Использование: /add <username>")
        return

    username = parts[1].strip()
    password = generate_password()

    try:
        config = load_current_config()
    except RuntimeError as exc:
        await message.answer(f"Ошибка: {exc}")
        return

    users = config.get("users", [])
    if any(user.get("name") == username for user in users):
        await message.answer(f"Пользователь {username} уже существует")
        return

    users.append({"name": username, "password": password})
    config["users"] = users

    try:
        save_config(config)
    except RuntimeError as exc:
        await message.answer(f"Ошибка при применении конфига: {exc}")
        return

    try:
        server_ip = get_public_ip()
    except RuntimeError as exc:
        await message.answer(f"Ошибка: {exc}")
        return

    client_config = build_client_config(server_ip, username, password, PORT_START)
    client_json = json.dumps(client_config, ensure_ascii=False, indent=2)
    mieru_link = build_mieru_link(server_ip, username, password, PORT_START, PORT_END)

    caption = (
        f"Ссылка: <code>{mieru_link}</code>"
    )

    await message.answer(caption)
    await message.answer_document(
        InputFile(io.BytesIO(client_json.encode("utf-8")), filename=f"mieru_{username}.json"),
        caption="Karing JSON для клиента",
    )


@dp.message(Command(commands=["del", "delete"]))
async def command_delete(message: types.Message) -> None:
    if not ensure_admin(message.from_user.id):
        await message.answer("Доступ запрещён")
        return

    parts = message.text.strip().split(maxsplit=1)
    if len(parts) < 2 or not parts[1].strip():
        await message.answer("Использование: /del <username>")
        return

    username = parts[1].strip()

    try:
        config = load_current_config()
    except RuntimeError as exc:
        await message.answer(f"Ошибка: {exc}")
        return

    users = config.get("users", [])
    filtered_users = [user for user in users if user.get("name") != username]
    if len(filtered_users) == len(users):
        await message.answer(f"Пользователь {username} не найден")
        return

    config["users"] = filtered_users

    try:
        save_config(config)
    except RuntimeError as exc:
        await message.answer(f"Ошибка при применении конфига: {exc}")
        return

    await message.answer(f"Пользователь <code>{username}</code> удалён")


async def main() -> None:
    await dp.start_polling(bot)


if __name__ == "__main__":
    import asyncio

    asyncio.run(main())

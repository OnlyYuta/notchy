#!/bin/bash
# CLI для управления статусами агентов в Notchy
IPC="$HOME/Library/Application Support/Notchy/ipc"; mkdir -p "$IPC"; FILE="$IPC/agents.json"

AGENT="$1"
ACTION="$2"

if [ -z "$AGENT" ]; then
    echo "Использование: $0 <claude|codex|antigravity|all> <on|off|toggle|status>"
    echo "Примеры:"
    echo "  $0 claude on       # Показать Claude в челке"
    echo "  $0 claude off      # Убрать Claude"
    echo "  $0 all off         # Скрыть всех агентов"
    echo "  $0 status          # Текущие активные агенты"
    exit 1
fi

# Инициализировать файл если его нет
if [ ! -f "$FILE" ]; then
    echo "[]" > "$FILE"
fi

python3 - << EOF
import json, sys

filepath = "$FILE"
agent = "$AGENT".lower()
action = "$ACTION".lower()

try:
    with open(filepath, "r") as f:
        active = json.load(f)
except Exception:
    active = []

if agent == "status":
    print("Активные агенты в челке:", active if active else "нет")
    sys.exit(0)

if agent == "all":
    if action == "off":
        active = []
    elif action == "on":
        active = ["claude", "codex", "antigravity"]
else:
    if action in ["on", "start", "active", "1", "true"]:
        if agent not in active:
            active.append(agent)
    elif action in ["off", "stop", "inactive", "0", "false", "close"]:
        if agent in active:
            active.remove(agent)
    elif action in ["toggle"]:
        if agent in active:
            active.remove(agent)
        else:
            active.append(agent)
    elif not action:
        # default to toggle
        if agent in active:
            active.remove(agent)
        else:
            active.append(agent)

# Canonical ordering
order = ["claude", "codex", "antigravity"]
active = [a for a in order if a in active]

with open(filepath, "w") as f:
    json.dump(active, f, indent=2)

print(f"Обновлено! Активные агенты: {active if active else 'нет (челка пустая)'}")
EOF

#!/bin/bash
IPC="$HOME/Library/Application Support/Notchy/ipc"; mkdir -p "$IPC"; FILE="$IPC/status.json"
CMD="$1"
AGENT="${2:-antigravity}"

if [ -z "$CMD" ]; then
    echo "Использование: $0 <prompt|working|done|idle> [antigravity|claude|codex]"
    echo "Примеры:"
    echo "  $0 prompt claude        # Раздвинуть челку, показать лого Claude"
    echo "  $0 working codex        # Показать лого Codex + 3 точки"
    echo "  $0 done antigravity     # Показать лого Antigravity + Готово"
    echo "  $0 idle                 # Свернуть челку"
    exit 1
fi

python3 - << EOF
import json

state_map = {
    "prompt": "promptReceived",
    "promptreceived": "promptReceived",
    "working": "working",
    "work": "working",
    "busy": "working",
    "done": "done",
    "finish": "done",
    "complete": "done",
    "idle": "idle",
    "close": "idle",
    "off": "idle"
}

cmd = "$CMD".lower()
target_state = state_map.get(cmd, "idle")

agent_raw = "$AGENT".lower()
if "claude" in agent_raw:
    target_agent = "claude"
elif "codex" in agent_raw:
    target_agent = "codex"
else:
    target_agent = "antigravity"

data = {
    "state": target_state,
    "agent": target_agent
}

with open("$FILE", "w") as f:
    json.dump(data, f, indent=2)

print(f"Статус челки обновлен на: {target_state} (Агент: {target_agent})")
EOF

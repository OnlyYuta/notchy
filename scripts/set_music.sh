#!/bin/bash
IPC="$HOME/Library/Application Support/Notchy/ipc"; mkdir -p "$IPC"; FILE="$IPC/music.json"
CMD="${1:-play}"
TITLE="${2:-Starboy}"
ARTIST="${3:-The Weeknd}"
ALBUM="${4:-Starboy}"
ARTWORK="${5:-$(cd "$(dirname "$0")/.." && pwd)/Resources/AntigravityLogo.png}"

if [ "$CMD" = "help" ] || [ "$CMD" = "--help" ] || [ "$CMD" = "-h" ]; then
    echo "Использование: $0 [play|pause|stop|clear] [Title] [Artist] [Album] [ArtworkPath]"
    echo "Примеры:"
    echo "  $0 play \"Blinding Lights\" \"The Weeknd\""
    echo "  $0 pause"
    echo "  $0 stop"
    exit 0
fi

python3 - << EOF
import json

cmd = "$CMD".lower()

if cmd in ["stop", "clear", "reset"]:
    data = {"action": "clear"}
    with open("$FILE", "w") as f:
        json.dump(data, f, indent=2)
    print("Музыкальный визуализатор сброшен (возврат к системе)")
elif cmd in ["pause", "paused"]:
    data = {
        "playing": False,
        "title": "$TITLE",
        "artist": "$ARTIST",
        "album": "$ALBUM",
        "artwork_path": "$ARTWORK"
    }
    with open("$FILE", "w") as f:
        json.dump(data, f, indent=2)
    print("Воспроизведение поставлено на паузу")
else:
    data = {
        "playing": True,
        "title": "$TITLE",
        "artist": "$ARTIST",
        "album": "$ALBUM",
        "artwork_path": "$ARTWORK"
    }
    with open("$FILE", "w") as f:
        json.dump(data, f, indent=2)
    print(f"Запущено воспроизведение: '$TITLE' - '$ARTIST'")
EOF

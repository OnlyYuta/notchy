#!/bin/bash
# Собирает универсальный (arm64 + x86_64) Release и упаковывает в Notchy.dmg
set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

BUILD="$DIR/.build/release"
STAGE="$DIR/.build/dmg-stage"
APP="$BUILD/Build/Products/Release/Notchy.app"
DMG="$DIR/Notchy.dmg"

echo "🔨 Release-сборка (arm64 + x86_64)..."
xcodebuild -project Notchy.xcodeproj -scheme Notchy \
           -derivedDataPath "$BUILD" -configuration Release \
           ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
           CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="-" build | tail -3

echo "🔏 Подпись ad-hoc..."
xattr -cr "$APP"
# Требование по идентификатору (не cdhash): разрешения macOS переживают обновление приложения
codesign --force --sign - -r='designated => identifier "com.local.DynamicNotch"' "$APP"
codesign --verify --deep --strict "$APP"

echo "📦 Подготовка образа..."
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Если macOS блокирует запуск.command" <<'CMD'
#!/bin/bash
# Снимает карантин macOS с Notchy (приложение не подписано сертификатом Apple Developer).
APP="/Applications/Notchy.app"
if [ ! -d "$APP" ]; then
  echo "Сначала перетащите Notchy в папку «Программы» (Applications)."
  read -n 1 -s -r -p "Нажмите любую клавишу..."; exit 1
fi
xattr -dr com.apple.quarantine "$APP"
open "$APP"
echo "Готово: Notchy запущен."
CMD
chmod +x "$STAGE/Если macOS блокирует запуск.command"

cat > "$STAGE/Установка.txt" <<'TXT'
Notchy — установка

1. Перетащите Notchy.app в папку «Программы» (Applications).
2. Запустите Notchy из «Программ».
3. Если macOS пишет «приложение повреждено» или «разработчик не подтверждён»:
   • правый клик по Notchy → «Открыть» → «Открыть», либо
   • запустите «Если macOS блокирует запуск.command» (правый клик → «Открыть»), либо
   • в Терминале: xattr -dr com.apple.quarantine /Applications/Notchy.app
4. Следуйте окну приветствия и выдайте разрешения (запись экрана, универсальный доступ).

Хуки для Claude Code, Codex, Cursor и Antigravity регистрируются автоматически при запуске
(резервные копии конфигов: *.notchy-backup). Отключить: меню приложения →
«Удалить хуки из конфигов агентов».
Требуется macOS 13 или новее.
TXT

hdiutil create -volname "Notchy" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "✅ Готово: $DMG ($(du -h "$DMG" | cut -f1))"

#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
cd "$DIR"

echo "🔨 Сборка Notchy..."
xcodebuild -project Notchy.xcodeproj \
           -scheme Notchy \
           -derivedDataPath .build/DerivedData \
           -configuration Debug \
           build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="-"

APP_PATH=".build/DerivedData/Build/Products/Debug/Notchy.app"
echo "🔏 Подпись приложения ad-hoc для сохранения системных разрешений..."
# Identifier-based requirement (not cdhash): macOS keeps Accessibility/Automation grants across rebuilds.
# Debug dylibs are signed first, without the requirement (it names the app only), and no --deep.
for d in "$APP_PATH"/Contents/MacOS/*.dylib; do codesign --force --sign - "$d" 2>/dev/null || true; done
codesign --force --sign - -r='designated => identifier "com.local.DynamicNotch"' "$APP_PATH" 2>/dev/null || true

echo "🚀 Запуск $APP_PATH..."
# Завершаем предыдущий экземпляр если запущен
killall Notchy 2>/dev/null || true

open "$APP_PATH"
echo "✅ Приложение успешно запущено! Наведите курсор на челку вверху экрана."

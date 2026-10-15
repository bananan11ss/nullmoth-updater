#!/bin/bash
# Снимает с NullMoth Updater метку «скачано из интернета» (карантин Gatekeeper) и открывает его.
# Приложение подписано ad-hoc, без сертификата Apple, поэтому macOS не даёт открыть его двойным щелчком.
# Скрипт трогает только /Applications/NullMoth Updater.app и ничего не отключает в системе.

APP="/Applications/NullMoth Updater.app"
echo "NullMoth Updater: помощник первого запуска"
echo

if [ ! -d "$APP" ]; then
  echo "Не нашёл $APP"
  echo "Сначала перетащи «NullMoth Updater» в папку «Программы» (Applications) в окне диска, потом запусти меня снова."
  echo; read -r -p "Нажми Enter, чтобы закрыть…" _
  exit 1
fi

if xattr -dr com.apple.quarantine "$APP" 2>/dev/null; then
  echo "Готово: карантин снят."
else
  echo "Без прав администратора снять карантин не вышло, macOS спросит пароль."
  sudo xattr -dr com.apple.quarantine "$APP" || { echo "Не получилось."; read -r -p "Enter — закрыть" _; exit 1; }
  echo "Готово: карантин снят."
fi

echo "Открываю NullMoth Updater…"
open "$APP"
echo "Это окно можно закрыть."
exit 0

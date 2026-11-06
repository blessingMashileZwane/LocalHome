#!/usr/bin/env bash
# Build, install, migrate/seed the debug app, and launch LocalHome.
set -euo pipefail

cd "$(dirname "$0")/../android-app"

PACKAGE="com.pyansofyan.localhome"
OLD_PACKAGE="com.pyansofyan.himost_camera"

flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk

# Launch once so the new package creates its shared_prefs store.
adb shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 2

python3 ../scripts/inject_lanpass.py

# Relaunch with the migrated profile store.
adb shell am force-stop "$PACKAGE"
adb shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true

if adb shell pm list packages | grep -q "package:${OLD_PACKAGE}"; then
  adb uninstall "$OLD_PACKAGE" >/dev/null 2>&1 || true
  echo "Removed the previous HiMost Local app after migration."
fi

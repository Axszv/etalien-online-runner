#!/usr/bin/env bash
set -euo pipefail

apk="${1:?APK path is required}"
out="${2:-diagnostics}"
package_name="com.etalien.booster"
mkdir -p "$out"

# A stalled ADB transport must fail the probe and leave the always-run log
# collection steps a chance to preserve the container state.
adb_run() {
  timeout --foreground --kill-after=10s 90s adb "$@"
}

adb_quick() {
  timeout --foreground --kill-after=2s 5s adb "$@"
}

adb_run connect 127.0.0.1:5555 | tee "$out/adb-connect.txt"
if ! adb_quick -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>/dev/null \
    | tr -d '\r' | grep -q '^1$'; then
  echo "Redroid preflight passed, but Android is unavailable over ADB" >&2
  exit 2
fi

export ANDROID_SERIAL=127.0.0.1:5555
adb_run shell getprop > "$out/getprop.txt"
{
  echo "host_arch=$(uname -m)"
  echo "device_abi=$(adb_run shell getprop ro.product.cpu.abi | tr -d '\r')"
  echo "device_abilist=$(adb_run shell getprop ro.product.cpu.abilist | tr -d '\r')"
  echo "hardware=$(adb_run shell getprop ro.hardware | tr -d '\r')"
  echo "model=$(adb_run shell getprop ro.product.model | tr -d '\r')"
  echo "native_bridge=$(adb_run shell getprop ro.dalvik.vm.native.bridge | tr -d '\r')"
} | tee "$out/environment.txt"

adb_run install -r "$apk" | tee "$out/install.txt"
adb_run logcat -c
adb_run shell monkey -p "$package_name" -c android.intent.category.LAUNCHER 1 \
  > "$out/launch.txt" 2>&1 || true
sleep 15

capture_ui() {
  local name="$1"
  adb_run shell rm -f "/sdcard/$name.xml" >/dev/null 2>&1 || true
  adb_run shell uiautomator dump "/sdcard/$name.xml" \
      > "$out/uiautomator-$name.txt" 2>&1 || true
  adb_run pull "/sdcard/$name.xml" "$out/$name.xml" >/dev/null 2>&1 || true
  adb_run exec-out screencap -p > "$out/$name.png" || true
}

capture_ui screen-initial
if grep -q 'id/UIConfirm' "$out/screen-initial.xml" 2>/dev/null; then
  adb_run shell input tap 717 1484
  sleep 15
fi

node scripts/create-android-session-prefs.mjs /tmp/spUtils.xml
adb_run push /tmp/spUtils.xml /data/local/tmp/spUtils.xml >/dev/null
app_data="/data/user/0/$package_name"
uid="$(adb_run shell stat -c '%u' "$app_data" | tr -d '\r')"
adb_run shell am force-stop "$package_name"
adb_run shell mkdir -p "$app_data/shared_prefs"
adb_run shell cp /data/local/tmp/spUtils.xml "$app_data/shared_prefs/spUtils.xml"
adb_run shell chown "$uid:$uid" "$app_data/shared_prefs/spUtils.xml"
adb_run shell chmod 660 "$app_data/shared_prefs/spUtils.xml"

set +e
adb_run shell am start -W -n \
  "$package_name/com.etalien.booster.ui.MobleADTaskListAndProductActivity" \
  > "$out/start-mobile-activity.txt" 2>&1
start_code=$?
set -e
if [[ "$start_code" -ne 0 ]]; then
  adb_run shell monkey -p "$package_name" -c android.intent.category.LAUNCHER 1 \
    > "$out/session-launch.txt" 2>&1 || true
  sleep 15
  adb_run shell input tap 900 2150
  sleep 5
  adb_run shell input tap 330 430
fi

sleep 90
capture_ui screen-mobile-reward
adb_run shell dumpsys activity activities > "$out/activities.txt" || true
adb_run logcat -d -v threadtime > "$out/logcat.txt" || true
node -e 'const fs=require("fs"); const p=process.argv[1]; const t=process.env.ETALIEN_TOKEN; const s=fs.readFileSync(p,"utf8"); fs.writeFileSync(p,s.split(t).join("[REDACTED]"));' "$out/logcat.txt"

if grep -q 'id/UIADSubmitText' "$out/screen-mobile-reward.xml" 2>/dev/null; then
  button_text="$(sed -n 's/.*resource-id="com\.etalien\.booster:id\/UIADSubmitText"[^>]*text="\([^"]*\)".*/\1/p' "$out/screen-mobile-reward.xml" | head -n 1)"
  echo "mobile_reward_page=true" | tee "$out/probe-status.txt"
  echo "button_text=$button_text" | tee -a "$out/probe-status.txt"
  exit 0
fi

echo "mobile_reward_page=false" | tee "$out/probe-status.txt"
exit 3

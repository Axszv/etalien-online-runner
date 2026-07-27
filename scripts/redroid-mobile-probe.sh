#!/usr/bin/env bash
set -euo pipefail

apk="${1:?APK path is required}"
out="${2:-diagnostics}"
package_name="com.etalien.booster"
mkdir -p "$out"

adb connect 127.0.0.1:5555 | tee "$out/adb-connect.txt"
for attempt in $(seq 1 90); do
  if adb -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>/dev/null \
      | tr -d '\r' | grep -q '^1$'; then
    break
  fi
  if [[ "$attempt" == "90" ]]; then
    echo "Redroid did not finish booting" >&2
    exit 2
  fi
  sleep 2
done

export ANDROID_SERIAL=127.0.0.1:5555
adb shell getprop > "$out/getprop.txt"
{
  echo "host_arch=$(uname -m)"
  echo "device_abi=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
  echo "device_abilist=$(adb shell getprop ro.product.cpu.abilist | tr -d '\r')"
  echo "hardware=$(adb shell getprop ro.hardware | tr -d '\r')"
  echo "model=$(adb shell getprop ro.product.model | tr -d '\r')"
  echo "native_bridge=$(adb shell getprop ro.dalvik.vm.native.bridge | tr -d '\r')"
} | tee "$out/environment.txt"

adb install -r "$apk" | tee "$out/install.txt"
adb logcat -c
adb shell monkey -p "$package_name" -c android.intent.category.LAUNCHER 1 \
  > "$out/launch.txt" 2>&1 || true
sleep 15

capture_ui() {
  local name="$1"
  adb shell rm -f "/sdcard/$name.xml" >/dev/null 2>&1 || true
  adb shell uiautomator dump "/sdcard/$name.xml" \
    > "$out/uiautomator-$name.txt" 2>&1 || true
  adb pull "/sdcard/$name.xml" "$out/$name.xml" >/dev/null 2>&1 || true
  adb exec-out screencap -p > "$out/$name.png" || true
}

capture_ui screen-initial
if grep -q 'id/UIConfirm' "$out/screen-initial.xml" 2>/dev/null; then
  adb shell input tap 717 1484
  sleep 15
fi

node scripts/create-android-session-prefs.mjs /tmp/spUtils.xml
adb push /tmp/spUtils.xml /data/local/tmp/spUtils.xml >/dev/null
app_data="/data/user/0/$package_name"
uid="$(adb shell stat -c '%u' "$app_data" | tr -d '\r')"
adb shell am force-stop "$package_name"
adb shell mkdir -p "$app_data/shared_prefs"
adb shell cp /data/local/tmp/spUtils.xml "$app_data/shared_prefs/spUtils.xml"
adb shell chown "$uid:$uid" "$app_data/shared_prefs/spUtils.xml"
adb shell chmod 660 "$app_data/shared_prefs/spUtils.xml"

set +e
adb shell am start -W -n \
  "$package_name/com.etalien.booster.ui.MobleADTaskListAndProductActivity" \
  > "$out/start-mobile-activity.txt" 2>&1
start_code=$?
set -e
if [[ "$start_code" -ne 0 ]]; then
  adb shell monkey -p "$package_name" -c android.intent.category.LAUNCHER 1 \
    > "$out/session-launch.txt" 2>&1 || true
  sleep 15
  adb shell input tap 900 2150
  sleep 5
  adb shell input tap 330 430
fi

sleep 90
capture_ui screen-mobile-reward
adb shell dumpsys activity activities > "$out/activities.txt" || true
adb logcat -d -v threadtime > "$out/logcat.txt" || true
node -e 'const fs=require("fs"); const p=process.argv[1]; const t=process.env.ETALIEN_TOKEN; const s=fs.readFileSync(p,"utf8"); fs.writeFileSync(p,s.split(t).join("[REDACTED]"));' "$out/logcat.txt"

if grep -q 'id/UIADSubmitText' "$out/screen-mobile-reward.xml" 2>/dev/null; then
  button_text="$(sed -n 's/.*resource-id="com\.etalien\.booster:id\/UIADSubmitText"[^>]*text="\([^"]*\)".*/\1/p' "$out/screen-mobile-reward.xml" | head -n 1)"
  echo "mobile_reward_page=true" | tee "$out/probe-status.txt"
  echo "button_text=$button_text" | tee -a "$out/probe-status.txt"
  exit 0
fi

echo "mobile_reward_page=false" | tee "$out/probe-status.txt"
exit 3

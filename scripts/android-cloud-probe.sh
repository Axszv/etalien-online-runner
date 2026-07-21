#!/usr/bin/env bash
set -u

apk="${1:?APK path is required}"
out="${2:-diagnostics}"
mkdir -p "$out"

adb wait-for-device
adb shell getprop > "$out/getprop.txt"
{
  echo "host_arch=$(uname -m)"
  echo "device_abi=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
  echo "device_abilist=$(adb shell getprop ro.product.cpu.abilist | tr -d '\r')"
  echo "native_bridge=$(adb shell getprop ro.dalvik.vm.native.bridge | tr -d '\r')"
  echo "kvm=$(test -r /dev/kvm && echo available || echo unavailable)"
} | tee "$out/environment.txt"

adb shell pm list packages -3 | sort > "$out/packages-before.txt"
set +e
adb install -r "$apk" > "$out/install.txt" 2>&1
install_code=$?
set -e
cat "$out/install.txt"

if [[ $install_code -ne 0 ]]; then
  echo "INSTALL_FAILED exit=$install_code" | tee "$out/probe-status.txt"
  adb logcat -d -v threadtime > "$out/logcat.txt" || true
  exit "$install_code"
fi

adb shell pm list packages -3 | sort > "$out/packages-after.txt"
package_name="$({ comm -13 "$out/packages-before.txt" "$out/packages-after.txt" || true; } \
  | sed -n 's/^package://p' | head -n 1 | tr -d '\r')"
if [[ -z "$package_name" ]]; then
  package_name="com.etalien.booster"
fi
echo "package=$package_name" | tee -a "$out/environment.txt"

for permission in \
  android.permission.READ_PHONE_STATE \
  android.permission.ACCESS_COARSE_LOCATION \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.READ_EXTERNAL_STORAGE \
  android.permission.WRITE_EXTERNAL_STORAGE
do
  adb shell pm grant "$package_name" "$permission" > /dev/null 2>&1 || true
done

adb logcat -c
adb shell monkey -p "$package_name" -c android.intent.category.LAUNCHER 1 \
  > "$out/launch.txt" 2>&1 || true
sleep 15

capture_ui() {
  local name="$1"
  adb shell uiautomator dump "/sdcard/$name.xml" \
    > "$out/uiautomator-$name.txt" 2>&1 || true
  adb pull "/sdcard/$name.xml" "$out/$name.xml" > /dev/null 2>&1 || true
  adb exec-out screencap -p > "$out/$name.png" || true
}

capture_ui screen-initial
if grep -q 'id/UIConfirm' "$out/screen-initial.xml" 2>/dev/null; then
  adb shell input tap 717 1484
  echo "privacy_confirm=clicked" | tee -a "$out/environment.txt"
  sleep 20
else
  echo "privacy_confirm=not_present" | tee -a "$out/environment.txt"
fi
capture_ui screen-after-consent

if [[ -n "${ETALIEN_TOKEN:-}" ]]; then
  adb root > "$out/adb-root.txt" 2>&1 || true
  adb wait-for-device
  node scripts/create-android-session-prefs.mjs /tmp/spUtils.xml
  adb push /tmp/spUtils.xml /data/local/tmp/spUtils.xml > /dev/null
  app_data="/data/user/0/$package_name"
  owner="$(adb shell stat -c '%u:%g' "$app_data/shared_prefs/spUtils.xml" | tr -d '\r')"
  adb shell am force-stop "$package_name"
  adb shell cp /data/local/tmp/spUtils.xml "$app_data/shared_prefs/spUtils.xml"
  adb shell chown "$owner" "$app_data/shared_prefs/spUtils.xml"
  adb shell chmod 660 "$app_data/shared_prefs/spUtils.xml"
  adb shell monkey -p "$package_name" -c android.intent.category.LAUNCHER 1 \
    > "$out/session-launch.txt" 2>&1 || true
  sleep 20
  capture_ui screen-with-session
  if grep -q 'id/UISubmit' "$out/screen-with-session.xml" 2>/dev/null; then
    adb shell input tap 162 567
    sleep 3
  fi
  adb shell input tap 900 2100
  sleep 12
  capture_ui screen-profile
  echo "session_injected=true" | tee -a "$out/environment.txt"
fi

adb shell dumpsys package "$package_name" > "$out/package.txt" || true
adb shell dumpsys activity activities > "$out/activities.txt" || true
adb shell dumpsys window windows > "$out/windows.txt" || true
adb logcat -d -v threadtime > "$out/logcat.txt" || true

if [[ -n "${ETALIEN_TOKEN:-}" ]]; then
  node -e 'const fs=require("fs"); const p=process.argv[1]; const t=process.env.ETALIEN_TOKEN; const s=fs.readFileSync(p,"utf8"); fs.writeFileSync(p,s.split(t).join("[REDACTED]"));' "$out/logcat.txt"
  echo "App-data export skipped because a session was injected." > "$out/app-data-tar.txt"
else
  adb root > "$out/adb-root.txt" 2>&1 || true
  adb wait-for-device || true
  app_data="/data/user/0/$package_name"
  adb shell find "$app_data" -maxdepth 4 -type f \
    > "$out/app-data-files.txt" 2>&1 || true
  adb exec-out tar -C "$app_data" -cf - shared_prefs files databases \
    > "$out/app-data.tar" 2> "$out/app-data-tar.txt" || true
fi

pid="$(adb shell pidof "$package_name" | tr -d '\r' || true)"
if [[ -n "$pid" ]]; then
  echo "LAUNCH_OK package=$package_name pid=$pid" | tee "$out/probe-status.txt"
  exit 0
fi

if grep -q '>>> com\.etalien\.booster <<<' "$out/logcat.txt" 2>/dev/null; then
  echo "NATIVE_CRASH package=$package_name" | tee "$out/probe-status.txt"
  exit 3
fi

echo "LAUNCH_FAILED package=$package_name" | tee "$out/probe-status.txt"
exit 2

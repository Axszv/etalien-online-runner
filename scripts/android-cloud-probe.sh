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

adb shell dumpsys package "$package_name" > "$out/package.txt" || true
adb shell dumpsys activity activities > "$out/activities.txt" || true
adb shell dumpsys window windows > "$out/windows.txt" || true
adb logcat -d -v threadtime > "$out/logcat.txt" || true

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

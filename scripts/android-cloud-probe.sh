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

adb logcat -c
adb shell monkey -p "$package_name" -c android.intent.category.LAUNCHER 1 \
  > "$out/launch.txt" 2>&1 || true
sleep 25

adb shell dumpsys package "$package_name" > "$out/package.txt" || true
adb shell dumpsys activity activities > "$out/activities.txt" || true
adb shell dumpsys window windows > "$out/windows.txt" || true
adb shell uiautomator dump /sdcard/window.xml > "$out/uiautomator.txt" 2>&1 || true
adb pull /sdcard/window.xml "$out/window.xml" > /dev/null 2>&1 || true
adb exec-out screencap -p > "$out/screen.png" || true
adb logcat -d -v threadtime > "$out/logcat.txt" || true

pid="$(adb shell pidof "$package_name" | tr -d '\r' || true)"
if [[ -n "$pid" ]]; then
  echo "LAUNCH_OK package=$package_name pid=$pid" | tee "$out/probe-status.txt"
  exit 0
fi

echo "LAUNCH_FAILED package=$package_name" | tee "$out/probe-status.txt"
exit 2

#!/usr/bin/env bash
set -euo pipefail

out="${1:-diagnostics}"
mkdir -p "$out"

adb wait-for-device
adb root > "$out/device-profile-adb-root.txt" 2>&1 || true
adb wait-for-device

# Mirror LDPlayer's configurable identity surface without committing private
# telephony identifiers. The account's existing device secret supplies a
# stable Android ID for this isolated probe.
if [[ -n "${ETALIEN_DVC:-}" ]]; then
  android_id="${ETALIEN_DVC:0:16}"
  adb shell settings put secure android_id "$android_id" > /dev/null 2>&1 || true
fi

# Keep ADB available to the runner while presenting normal user-facing flags
# to SDKs that inspect Settings.Global.
adb shell settings put global development_settings_enabled 0 > /dev/null 2>&1 || true
adb shell settings put global adb_enabled 0 > /dev/null 2>&1 || true
adb shell setprop persist.sys.timezone Asia/Shanghai > /dev/null 2>&1 || true
adb shell setprop gsm.sim.operator.numeric 46000 > /dev/null 2>&1 || true
adb shell setprop gsm.operator.numeric 46000 > /dev/null 2>&1 || true
adb shell setprop gsm.sim.operator.iso-country cn > /dev/null 2>&1 || true
adb shell setprop gsm.operator.iso-country cn > /dev/null 2>&1 || true
adb shell setprop gsm.sim.operator.alpha 'China Mobile' > /dev/null 2>&1 || true
adb shell setprop gsm.operator.alpha 'China Mobile' > /dev/null 2>&1 || true
adb emu gsm data home > /dev/null 2>&1 || true
adb emu gsm voice home > /dev/null 2>&1 || true

{
  echo "model=$(adb shell getprop ro.product.model | tr -d '\r')"
  echo "manufacturer=$(adb shell getprop ro.product.manufacturer | tr -d '\r')"
  echo "brand=$(adb shell getprop ro.product.brand | tr -d '\r')"
  echo "device=$(adb shell getprop ro.product.device | tr -d '\r')"
  echo "build_type=$(adb shell getprop ro.build.type | tr -d '\r')"
  echo "build_tags=$(adb shell getprop ro.build.tags | tr -d '\r')"
  echo "characteristics=$(adb shell getprop ro.build.characteristics | tr -d '\r')"
  echo "hardware=$(adb shell getprop ro.hardware | tr -d '\r')"
  echo "kernel_qemu=$(adb shell getprop ro.kernel.qemu | tr -d '\r')"
  echo "abi=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
  echo "native_bridge=$(adb shell getprop ro.dalvik.vm.native.bridge | tr -d '\r')"
  echo "sim_operator=$(adb shell getprop gsm.sim.operator.numeric | tr -d '\r')"
  echo "timezone=$(adb shell getprop persist.sys.timezone | tr -d '\r')"
  echo "android_id_configured=$([[ -n "${ETALIEN_DVC:-}" ]] && echo true || echo false)"
  echo "developer_settings=$(adb shell settings get global development_settings_enabled | tr -d '\r')"
  echo "adb_setting=$(adb shell settings get global adb_enabled | tr -d '\r')"
} | tee "$out/ldplayer-like-profile.txt"

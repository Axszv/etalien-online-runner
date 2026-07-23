#!/usr/bin/env bash
set -euo pipefail

out="${1:-diagnostics}"
mkdir -p "$out"

adb wait-for-device
adb root > "$out/device-profile-adb-root.txt" 2>&1 || true

wait_boot() {
  adb wait-for-device > /dev/null 2>&1 || true
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    state="$(adb get-state 2>/dev/null | tr -d '\r' || true)"
    boot="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [[ "$state" == "device" && "$boot" == "1" ]]; then
      return 0
    fi
    sleep 3
  done
  echo "ADB did not reach a fully booted device" >&2
  return 1
}

wait_boot

# Emulator -writable-system exposes an overlayfs mount. The first remount only
# enables the overlay and requires a reboot; the second remount makes the
# overlay writable so build.prop edits can be persisted for the next boot.
adb remount > "$out/device-profile-remount.txt" 2>&1 || true
adb reboot > "$out/device-profile-overlay-reboot.txt" 2>&1 || true
wait_boot
adb root > "$out/device-profile-adb-root-second.txt" 2>&1 || true
wait_boot
adb remount > "$out/device-profile-remount-second.txt" 2>&1 || true

set_prop() {
  local key="$1"
  local value="$2"
  for file in /system/build.prop /system_ext/build.prop /product/build.prop \
    /vendor/build.prop /odm/build.prop; do
    adb shell "if [ -f '$file' ]; then sed -i 's|^$key=.*|$key=$value|' '$file'; grep -q '^$key=' '$file' || echo '$key=$value' >> '$file'; fi" \
      > /dev/null 2>&1 || true
  done
}

set_prop ro.product.model 25060RK16C
set_prop ro.product.manufacturer REDMI
set_prop ro.product.brand REDMI
set_prop ro.product.name onyx
set_prop ro.product.device onyx
set_prop ro.product.product.model 25060RK16C
set_prop ro.product.product.manufacturer REDMI
set_prop ro.product.product.brand REDMI
set_prop ro.product.product.name onyx
set_prop ro.product.product.device onyx
set_prop ro.product.system.model 25060RK16C
set_prop ro.product.system.manufacturer REDMI
set_prop ro.product.system.brand REDMI
set_prop ro.product.system.name onyx
set_prop ro.product.system.device onyx
set_prop ro.product.vendor.model 25060RK16C
set_prop ro.product.vendor.manufacturer REDMI
set_prop ro.product.vendor.brand REDMI
set_prop ro.product.vendor.name onyx
set_prop ro.product.vendor.device onyx
set_prop ro.build.characteristics default
set_prop ro.build.type user
set_prop ro.build.tags release-keys
set_prop ro.build.fingerprint REDMI/onyx/onyx:14/UP1A.231005.007/20260723:user/release-keys

adb reboot > "$out/device-profile-reboot.txt" 2>&1 || true
wait_boot

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

adb shell getprop | tr -d '\r' > "$out/effective-getprop.txt"
get_prop() {
  local key="$1"
  sed -n "s/^\\[$key\\]: \\[\\(.*\\)\\]$/\\1/p" "$out/effective-getprop.txt" | head -n 1
}
{
  echo "model=$(get_prop ro.product.model)"
  echo "manufacturer=$(get_prop ro.product.manufacturer)"
  echo "brand=$(get_prop ro.product.brand)"
  echo "device=$(get_prop ro.product.device)"
  echo "build_type=$(get_prop ro.build.type)"
  echo "build_tags=$(get_prop ro.build.tags)"
  echo "characteristics=$(get_prop ro.build.characteristics)"
  echo "hardware=$(get_prop ro.hardware)"
  echo "kernel_qemu=$(get_prop ro.kernel.qemu)"
  echo "abi=$(get_prop ro.product.cpu.abi)"
  echo "native_bridge=$(get_prop ro.dalvik.vm.native.bridge)"
  echo "sim_operator=$(get_prop gsm.sim.operator.numeric)"
  echo "timezone=$(get_prop persist.sys.timezone)"
  echo "android_id_configured=$([[ -n "${ETALIEN_DVC:-}" ]] && echo true || echo false)"
  echo "developer_settings=$(adb shell settings get global development_settings_enabled | tr -d '\r')"
  echo "adb_setting=$(adb shell settings get global adb_enabled | tr -d '\r')"
} | tee "$out/ldplayer-like-profile.txt"

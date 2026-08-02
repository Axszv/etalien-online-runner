#!/usr/bin/env bash
set -euo pipefail

apk="${1:?APK path is required}"
out="${2:-diagnostics}"
package_name="com.etalien.booster"
container="redroid"
ad_attempts="${ETALIEN_AD_ATTEMPTS:-0}"
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
adb_run shell am start -W -n \
  "$package_name/com.etalien.booster.ui.SplashActivity" \
  > "$out/launch.txt" 2>&1 || true
sleep 15

capture_ui() {
  local name="$1"
  local attempt
  rm -f "$out/$name.xml"
  for attempt in 1 2 3; do
    adb_run shell rm -f "/sdcard/$name.xml" >/dev/null 2>&1 || true
    adb_run shell uiautomator dump "/sdcard/$name.xml" \
        >> "$out/uiautomator-$name.txt" 2>&1 || true
    adb_run pull "/sdcard/$name.xml" "$out/$name.xml" >/dev/null 2>&1 || true
    [[ -s "$out/$name.xml" ]] && break
    sleep 2
  done
  adb_run exec-out screencap -p > "$out/$name.png" || true
}

capture_screen() {
  adb_run exec-out screencap -p > "$out/$1.png" || true
}

pc_ad_is_open() {
  adb_quick shell dumpsys activity activities 2>/dev/null \
    | grep -q 'topResumedActivity=.*KsRewardVideoActivity'
}

resource_center() {
  local xml="$1"
  local id="$2"
  node - "$xml" "$package_name:id/$id" <<'NODE'
const fs = require("fs");
const [file, id] = process.argv.slice(2);
const source = fs.readFileSync(file, "utf8");
const tag = source.match(/<node\b[^>]*>/g)?.find((item) =>
  item.includes(`resource-id="${id}"`));
const bounds = tag?.match(/bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/);
if (!bounds) process.exit(1);
console.log(`${Math.floor((+bounds[1] + +bounds[3]) / 2)} ${Math.floor((+bounds[2] + +bounds[4]) / 2)}`);
NODE
}

tap_resource() {
  local id="$1"
  local name="find-$id"
  local coordinates
  capture_ui "$name"
  coordinates="$(resource_center "$out/$name.xml" "$id")" || return 1
  adb_run shell input tap $coordinates
}

pc_progress() {
  local xml="$1"
  node - "$xml" "$package_name:id/UIStateTitle" <<'NODE'
const fs = require("fs");
const [file, id] = process.argv.slice(2);
const source = fs.readFileSync(file, "utf8");
const tag = source.match(/<node\b[^>]*>/g)?.find((item) =>
  item.includes(`resource-id="${id}"`));
const text = tag?.match(/text="([^"]*)"/)?.[1] || "";
const progress = text.match(/(\d+)\s*\/\s*(\d+)/);
if (!progress) process.exit(1);
console.log(`${progress[1]} ${progress[2]}`);
NODE
}

pc_ad_ready() {
  local xml="$1"
  node - "$xml" "$package_name:id/UIADSubmitText" <<'NODE'
const fs = require("fs");
const [file, id] = process.argv.slice(2);
const source = fs.readFileSync(file, "utf8");
const tag = source.match(/<node\b[^>]*>/g)?.find((item) =>
  item.includes(`resource-id="${id}"`));
const text = tag?.match(/text="([^"]*)"/)?.[1] || "";
const ready = text.includes("\u770b\u5e7f\u544a")
  && !text.includes("\u52a0\u8f7d")
  && !text.includes("\u7a0d\u7b49");
if (!ready) process.exit(1);
console.log(text);
NODE
}

capture_ui screen-initial
if grep -q 'id/UIConfirm' "$out/screen-initial.xml" 2>/dev/null; then
  adb_run shell input tap 717 1484
  sleep 15
fi

node scripts/create-android-session-prefs.mjs /tmp/spUtils.xml
app_data="/data/user/0/$package_name"
uid="$(docker exec "$container" stat -c '%u' "$app_data" | tr -d '\r')"
adb_run shell am force-stop "$package_name"
adb_run push /tmp/spUtils.xml /data/local/tmp/spUtils.xml >/dev/null
docker exec "$container" mkdir -p "$app_data/shared_prefs"
docker exec "$container" cp /data/local/tmp/spUtils.xml \
  "$app_data/shared_prefs/spUtils.xml"
docker exec "$container" chown "$uid:$uid" \
  "$app_data/shared_prefs/spUtils.xml"
docker exec "$container" chmod 660 "$app_data/shared_prefs/spUtils.xml"

adb_run shell am start -W -n \
  "$package_name/com.etalien.booster.ui.SplashActivity" \
  > "$out/session-launch.txt" 2>&1
sleep 20
capture_ui screen-session-main

for attempt in 1 2 3; do
  if ! grep -q 'id/UISubmit' "$out/screen-session-main.xml" 2>/dev/null; then
    break
  fi
  tap_resource UISubmit || true
  sleep 3
  capture_ui screen-session-main
done

# The target task is under My Games in PC acceleration mode. UISwitch is
# present only on that page, so use the bottom tab as a fallback when needed.
if ! tap_resource UISwitch; then
  adb_run shell input tap 540 2070
  sleep 5
  tap_resource UISwitch
fi

button_text=""
for attempt in $(seq 1 24); do
  sleep 5
  capture_ui screen-pc-reward
  if button_text="$(pc_ad_ready "$out/screen-pc-reward.xml")"; then
    break
  fi
done

if [[ -z "$button_text" ]] \
    || ! grep -q 'id/UIPCDurationCard' "$out/screen-pc-reward.xml" 2>/dev/null; then
  echo "pc_reward_page=false" | tee "$out/probe-status.txt"
  exit 3
fi

read -r before_count total_count \
  <<< "$(pc_progress "$out/screen-pc-reward.xml")"

reward_verified="false"
after_count="$before_count"
if (( ad_attempts > 0 )); then
  adb_run shell svc power stayon true >/dev/null 2>&1 || true
  tap_resource UIADSubmit

  ad_opened="false"
  for attempt in $(seq 1 30); do
    if pc_ad_is_open; then
      ad_opened="true"
      break
    fi
    sleep 2
  done
  if [[ "$ad_opened" != "true" ]]; then
    echo "PC rewarded ad did not open" >&2
    exit 5
  fi

  capture_screen screen-ad-started
  sleep 15
  capture_screen screen-ad-15s
  sleep 30
  capture_screen screen-ad-45s
  sleep 30
  capture_screen screen-ad-finished

  # Kuaishou's completed end card consumes KEYCODE_BACK. Its visible close/
  # skip control is centered near x=900 on the fixed 1080x2280 surface.
  for attempt in 1 2 3; do
    adb_run shell input tap 900 70 || true
    sleep 5
    pc_ad_is_open || break
  done

  if pc_ad_is_open; then
    adb_run shell am force-stop "$package_name"
    adb_run shell am start -W -n \
      "$package_name/com.etalien.booster.ui.SplashActivity" \
      > "$out/restart-after-ad.txt" 2>&1
    sleep 15
    capture_ui screen-restart-after-ad
    if ! grep -q 'id/UIPCDurationCard' \
        "$out/screen-restart-after-ad.xml" 2>/dev/null; then
      tap_resource UISwitch || true
      sleep 10
    fi
  fi

  for poll in $(seq 1 6); do
    sleep 10
    capture_ui "screen-pc-after-$poll"
    read -r after_count after_total \
      <<< "$(pc_progress "$out/screen-pc-after-$poll.xml" || echo "$before_count $total_count")"
    if (( after_count > before_count )); then
      reward_verified="true"
      break
    fi
  done
fi

adb_run shell dumpsys activity activities > "$out/activities.txt" || true
adb_run logcat -d -v threadtime > "$out/logcat.txt" || true
node -e 'const fs=require("fs"); const p=process.argv[1]; const t=process.env.ETALIEN_TOKEN; const s=fs.readFileSync(p,"utf8"); fs.writeFileSync(p,s.split(t).join("[REDACTED]"));' "$out/logcat.txt"

if (( ad_attempts > 0 )) && [[ "$reward_verified" != "true" ]]; then
  {
    echo "pc_reward_page=true"
    echo "reward_verified=false"
    echo "pc_progress_before=$before_count"
    echo "pc_progress_after=$after_count"
    echo "pc_progress_total=$total_count"
  } | tee "$out/probe-status.txt"
  exit 4
fi

echo "pc_reward_page=true" | tee "$out/probe-status.txt"
echo "button_text=$button_text" | tee -a "$out/probe-status.txt"
echo "pc_progress_before=$before_count" | tee -a "$out/probe-status.txt"
echo "pc_progress_total=$total_count" | tee -a "$out/probe-status.txt"
if (( ad_attempts > 0 )); then
  echo "reward_verified=true" | tee -a "$out/probe-status.txt"
  echo "pc_progress_after=$after_count" | tee -a "$out/probe-status.txt"
fi

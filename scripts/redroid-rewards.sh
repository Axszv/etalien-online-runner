#!/usr/bin/env bash
# ETAlien rewarded-ad runner: watches the mobile reward ladder and the
# My Games PC acceleration ladder inside Redroid, verifying every reward
# through the server protocol instead of trusting UI text.
#
# Env:
#   ETALIEN_MOBILE_ADS  max mobile ads to watch (0 = skip mobile)
#   ETALIEN_PC_ADS      max PC ads to watch (0 = navigate and report only)
#   ETALIEN_TOTAL_BUDGET  soft wall-clock budget in seconds (default 4500)
# Exit codes:
#   0 all planned rewards verified; 1 rounds exhausted with rewards left;
#   2 ADB preflight failed; 3 PC reward page unreachable; 6 protocol/token error
set -euo pipefail

apk="${1:?APK path is required}"
out="${2:-diagnostics}"
package_name="com.etalien.booster"
splash_activity="$package_name/com.etalien.booster.ui.SplashActivity"
mobile_activity="$package_name/com.etalien.booster.ui.MobleADTaskListAndProductActivity"
container="redroid"
mobile_ads="${ETALIEN_MOBILE_ADS:-0}"
pc_ads="${ETALIEN_PC_ADS:-0}"
total_budget="${ETALIEN_TOTAL_BUDGET:-4500}"
deadline=$((SECONDS + total_budget))
mkdir -p "$out"
: > "$out/probe-status.txt"

adb_run() {
  timeout --foreground --kill-after=10s 90s adb "$@"
}

adb_quick() {
  timeout --foreground --kill-after=2s 5s adb "$@"
}

# Every diagnostic channel may carry the session token or device id; run all
# captured output through this before it lands in public artifacts or logs.
redact_stream() {
  node -e '
    let data = "";
    process.stdin.on("data", (chunk) => { data += chunk; });
    process.stdin.on("end", () => {
      for (const secret of [process.env.ETALIEN_TOKEN, process.env.ETALIEN_DVC]) {
        if (secret) data = data.split(secret).join("[REDACTED]");
      }
      process.stdout.write(data);
    });
  '
}

collect_diagnostics() {
  local tag="${1:-final}"
  adb_quick shell dumpsys activity activities 2>/dev/null \
    | redact_stream > "$out/activities-$tag.txt" || true
  adb_quick logcat -d -v threadtime -t 5000 2>/dev/null \
    | redact_stream > "$out/logcat-$tag.txt" || true
  # Ad-SDK verdict lines go to stdout as well so failure causes survive
  # artifact expiry and stay visible in the run log itself.
  grep -aiE '80100|102006|no.?bid|no_?fill|RewardVideo|KsReward|onAdError|onRewardVerify|reward.*fail' \
    "$out/logcat-$tag.txt" 2>/dev/null \
    | tail -n 60 | tee "$out/ad-sdk-signatures-$tag.txt" || true
}

on_exit() {
  collect_diagnostics "exit$?" || true
}
trap on_exit EXIT

time_left() {
  (( SECONDS < deadline ))
}

protocol_snapshot() {
  node src/cli.mjs inspect > "$1" 2> "$out/inspect-error.txt"
}

protocol_value() {
  node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); const v=d[process.argv[2]]; console.log(v===undefined?"":v);' "$1" "$2"
}

ad_is_open() {
  local dump
  dump="$(adb_quick shell dumpsys activity activities 2>/dev/null || true)"
  local resumed
  resumed="$(grep -E 'topResumedActivity=|mResumedActivity:|ResumedActivity:' <<<"$dump" | tail -n 1)"
  if [[ -z "$resumed" ]]; then
    return 1
  fi
  # Treat any resumed activity outside the app's own known pages as a
  # rewarded-ad overlay. Enumerating SDK class names (KsReward...,
  # com.qq.e.ads.PortraitADActivity, pangle's TTRewardVideoActivity) cannot
  # stay exhaustive and missed GDT, which left the end card on screen for
  # every later round.
  if grep -Eqi 'SplashActivity|MainActivity|MobleADTaskListAndProductActivity|launcher3| ResolverActivity' <<<"$resumed"; then
    return 1
  fi
  return 0
}

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

# Close a rewarded-ad overlay and confirm it is actually gone. Blind taps have
# hit the end-card landing link instead of the close control, so prefer
# KEYCODE_BACK (Kuaishou's end card consumes it) and only tap the top-right
# close corner when the overlay is still up afterward.
close_reward_ad() {
  local mode="$1"
  local attempt
  for attempt in 1 2 3; do
    adb_run shell input keyevent 4 || true
    sleep 4
    ad_is_open || return 0
    adb_run shell input tap 985 88 || true
    sleep 4
    ad_is_open || return 0
  done
  hard_close_ad "$mode"
}

# Last-resort recovery when BACK/close taps cannot dismiss the overlay. An ad
# page left resumed blocks every later round's taps (they land inside the ad)
# and wedges screencap/uiautomator for minutes, so force-stop and re-enter
# the page instead of treating a stuck ad as irrecoverable.
hard_close_ad() {
  local mode="$1"
  echo "hard_close_ad invoked ($mode)" | tee -a "$out/probe-status.txt"
  adb_run shell am force-stop "$package_name" || true
  sleep 5
  if [[ "$mode" == "mobile" ]]; then
    enter_mobile_page "hard-close-mobile.txt"
    sleep 20
  else
    return_to_pc_page
  fi
  ad_is_open || return 0
  echo "hard_close_ad failed to clear the overlay" | tee -a "$out/probe-status.txt"
  return 1
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
const ready = text.includes("看广告")
  && !text.includes("加载")
  && !text.includes("稍等");
if (!ready) process.exit(1);
console.log(text);
NODE
}

enter_mobile_page() {
  local logname="$1"
  if ! docker exec "$container" /system/bin/am start -W -n "$mobile_activity" \
      > "$out/$logname" 2>&1; then
    adb_run shell monkey -p "$package_name" -c android.intent.category.LAUNCHER 1 \
      >> "$out/$logname" 2>&1 || true
    sleep 15
    adb_run shell input tap 900 2150 || true
    sleep 5
    adb_run shell input tap 330 430 || true
  fi
}

# Startup dialogs share resource ids with real page controls, so each is
# identified by its neighbors before tapping: the update dialog pairs
# UISubmit=立即更新 with UIClose; a bare UISubmit (我知道了) is a notice
# whose only safe action is itself; the installer security dialog is
# identified by its package and cancelled; UIConfirm is the privacy prompt.
dismiss_startup_dialogs() {
  for attempt in 1 2 3 4; do
    capture_ui screen-pc-entry
    if grep -q 'package="com.android.packageinstaller"' \
        "$out/screen-pc-entry.xml" 2>/dev/null; then
      adb_run shell input tap 235 1460 || true
      sleep 3
      continue
    fi
    if grep -q 'id/UIClose' "$out/screen-pc-entry.xml" 2>/dev/null; then
      tap_resource UIClose || true
      sleep 3
      continue
    fi
    if grep -q 'id/UIConfirm' "$out/screen-pc-entry.xml" 2>/dev/null; then
      tap_resource UIConfirm || true
      sleep 5
      continue
    fi
    if grep -q 'id/UISubmit' "$out/screen-pc-entry.xml" 2>/dev/null; then
      tap_resource UISubmit || true
      sleep 3
      continue
    fi
    break
  done
}

# Bring the app back to the main page and switch to the PC acceleration card.
return_to_pc_page() {
  adb_run shell am force-stop "$package_name" || true
  adb_run shell am start -W -n "$splash_activity" > "$out/pc-launch.txt" 2>&1 || true
  sleep 20
  capture_ui screen-pc-entry
  dismiss_startup_dialogs
  if ! tap_resource UISwitch; then
    adb_run shell input tap 540 2070 || true
    sleep 5
    tap_resource UISwitch || true
  fi
  return 0
}

# --- ADB preflight with retry: a freshly booted container may not expose the
# --- ADB transport immediately.
adb_run connect 127.0.0.1:5555 | tee "$out/adb-connect.txt"
preflight_ok="false"
for attempt in $(seq 1 12); do
  if adb_quick -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>/dev/null \
      | tr -d '\r' | grep -q '^1$'; then
    preflight_ok="true"
    break
  fi
  sleep 5
  adb_run connect 127.0.0.1:5555 >> "$out/adb-connect.txt" 2>&1 || true
done
if [[ "$preflight_ok" != "true" ]]; then
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

capture_ui screen-initial
if grep -q 'id/UIClose' "$out/screen-initial.xml" 2>/dev/null; then
  tap_resource UIClose || true
  sleep 5
  capture_ui screen-initial
fi
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
# A root-owned shared_prefs directory leaves the app unable to create any pref
# file: ad SDKs (pangle logged ~1900 "Couldn't create directory" errors) lose
# their frequency and config persistence and the ad pipeline degrades.
docker exec "$container" chown "$uid:$uid" "$app_data/shared_prefs"
docker exec "$container" chmod 770 "$app_data/shared_prefs"
docker exec "$container" cp /data/local/tmp/spUtils.xml \
  "$app_data/shared_prefs/spUtils.xml"
docker exec "$container" chown "$uid:$uid" \
  "$app_data/shared_prefs/spUtils.xml"
docker exec "$container" chmod 660 "$app_data/shared_prefs/spUtils.xml"
docker exec "$container" /system/bin/restorecon -R \
  "$app_data/shared_prefs" >/dev/null 2>&1 || true

# --- Protocol phase 0: fail fast on an expired token before spending time
# --- on any UI work.
if ! protocol_snapshot "$out/activity-start.json"; then
  {
    echo "protocol_error=true"
    echo "hint=ETALIEN_TOKEN may be expired; re-login required (src/cli.mjs login-password)"
    cat "$out/inspect-error.txt" 2>/dev/null || true
  } | tee -a "$out/probe-status.txt"
  exit 6
fi
watch0="$(protocol_value "$out/activity-start.json" userWatchCnt)"; watch0="${watch0:-0}"
next0="$(protocol_value "$out/activity-start.json" nextVideoCnt)"; next0="${next0:-0}"
video0="$(protocol_value "$out/activity-start.json" videoCnt)"; video0="${video0:-0}"
echo "protocol_start watch=$watch0 next=$next0 video=$video0" | tee -a "$out/probe-status.txt"

# --- Phase 1: mobile reward ladder.
mobile_ok=0
mobile_planned=0
if (( mobile_ads > 0 )) && [[ "$next0" != "0" ]]; then
  remaining=$((video0 - watch0))
  if (( remaining < 0 )); then remaining=0; fi
  mobile_planned=$remaining
  if (( mobile_planned > mobile_ads )); then mobile_planned=$mobile_ads; fi
  echo "mobile_planned=$mobile_planned" | tee -a "$out/probe-status.txt"
fi

if (( mobile_planned > 0 )); then
  adb_run shell svc power stayon true >/dev/null 2>&1 || true
  enter_mobile_page start-mobile-activity.txt
  sleep 90
  capture_ui screen-mobile-reward

  consecutive_fail=0
  rounds=$((mobile_planned + 2))
  for round in $(seq 1 "$rounds"); do
    if ! time_left; then
      echo "time budget exhausted before mobile round $round" | tee -a "$out/probe-status.txt"
      break
    fi
    if ! protocol_snapshot "$out/activity-before-$round.json"; then
      echo "mobile_round=$round protocol poll failed" | tee -a "$out/probe-status.txt"
      sleep 10
      continue
    fi
    before="$(protocol_value "$out/activity-before-$round.json" userWatchCnt)"; before="${before:-$watch0}"
    next_now="$(protocol_value "$out/activity-before-$round.json" nextVideoCnt)"; next_now="${next_now:-1}"
    if [[ "$next_now" == "0" ]]; then
      echo "mobile ladder complete at round $round" | tee -a "$out/probe-status.txt"
      break
    fi

    adb_run shell input tap 540 746
    sleep 15
    capture_screen "screen-mobile-ad-started-$round"
    sleep 60
    capture_screen "screen-mobile-ad-finished-$round"
    close_reward_ad mobile || true

    verified="false"
    for poll in $(seq 1 9); do
      sleep 10
      if ! protocol_snapshot "$out/activity-poll-$round-$poll.json"; then
        continue
      fi
      after="$(protocol_value "$out/activity-poll-$round-$poll.json" userWatchCnt)"
      after="${after:-$before}"
      if (( after > before )); then
        verified="true"
        break
      fi
    done
    if [[ "$verified" == "true" ]]; then
      mobile_ok=$((mobile_ok + 1))
      consecutive_fail=0
      echo "mobile_round=$round verified watch=$after" | tee -a "$out/probe-status.txt"
    else
      consecutive_fail=$((consecutive_fail + 1))
      echo "mobile_round=$round NOT verified (consecutive_fail=$consecutive_fail)" | tee -a "$out/probe-status.txt"
      collect_diagnostics "mobile-fail-$round"
      if (( consecutive_fail >= 2 )); then
        echo "mobile phase gave up after consecutive failures" | tee -a "$out/probe-status.txt"
        break
      fi
      adb_run shell am force-stop "$package_name" || true
      enter_mobile_page "restart-mobile-$round.txt"
      sleep 30
    fi
  done
  if ! protocol_snapshot "$out/activity-mobile-final.json"; then
    cp "$out/activity-start.json" "$out/activity-mobile-final.json" 2>/dev/null || true
  fi
else
  cp "$out/activity-start.json" "$out/activity-mobile-final.json" 2>/dev/null || true
  if (( mobile_ads > 0 )); then
    echo "mobile ladder already complete" | tee -a "$out/probe-status.txt"
  fi
fi

# --- Phase 2: My Games PC acceleration ladder. Navigation also happens when
# --- pc_ads=0 so the probe workflow keeps its dry-run reporting.
pc_ok=0
pc_planned=0
pc_before=0
pc_total=0
pc_page_reached="false"
pc_watch_enabled="false"
if (( pc_ads > 0 )); then
  pc_watch_enabled="true"
fi

return_to_pc_page
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
  echo "pc_reward_page=false" | tee -a "$out/probe-status.txt"
  exit 3
fi
pc_page_reached="true"
read -r pc_before pc_total <<< "$(pc_progress "$out/screen-pc-reward.xml" || echo "")"
pc_before="${pc_before:-0}"
pc_total="${pc_total:-0}"

if [[ "$pc_watch_enabled" == "true" ]]; then
  remaining_pc=$((pc_total - pc_before))
  if (( remaining_pc < 0 )); then remaining_pc=0; fi
  pc_planned=$remaining_pc
  if (( pc_planned > pc_ads )); then pc_planned=$pc_ads; fi
  # A missed UIStateTitle parse must not silently skip the whole PC ladder.
  if (( pc_planned == 0 )); then pc_planned=$pc_ads; fi
  echo "pc_start before=$pc_before total=$pc_total planned=$pc_planned" | tee -a "$out/probe-status.txt"
fi

if [[ "$pc_watch_enabled" == "true" ]] && (( pc_planned > 0 )); then
  adb_run shell svc power stayon true >/dev/null 2>&1 || true
  consecutive_fail=0
  rounds=$((pc_planned + 2))
  for round in $(seq 1 "$rounds"); do
    if ! time_left; then
      echo "time budget exhausted before PC round $round" | tee -a "$out/probe-status.txt"
      break
    fi
    capture_ui "screen-pc-round-$round"
    fresh="$(pc_progress "$out/screen-pc-round-$round.xml" || echo "")"
    if [[ -n "$fresh" ]]; then
      read -r pc_before pc_total <<< "$fresh"
      pc_before="${pc_before:-0}"
      pc_total="${pc_total:-0}"
    fi
    if (( pc_total > 0 )) && (( pc_before >= pc_total )); then
      echo "PC ladder complete at round $round" | tee -a "$out/probe-status.txt"
      break
    fi

    button_text=""
    for attempt in $(seq 1 24); do
      sleep 5
      capture_ui "screen-pc-ready-$round"
      if button_text="$(pc_ad_ready "$out/screen-pc-ready-$round.xml")"; then
        break
      fi
    done
    if [[ -z "$button_text" ]]; then
      consecutive_fail=$((consecutive_fail + 1))
      echo "pc_round=$round button never became ready (consecutive_fail=$consecutive_fail)" | tee -a "$out/probe-status.txt"
      collect_diagnostics "pc-notready-$round"
      if (( consecutive_fail >= 2 )); then
        echo "PC phase gave up waiting for the ad button" | tee -a "$out/probe-status.txt"
        break
      fi
      return_to_pc_page
      continue
    fi

    tap_resource UIADSubmit || true
    ad_opened="false"
    for attempt in $(seq 1 90); do
      if ad_is_open; then
        ad_opened="true"
        break
      fi
      sleep 2
      # The SDK sometimes swallows the first tap (no load request in the
      # logcat after it); re-tap the still-visible button before giving up.
      if (( attempt == 45 )); then
        tap_resource UIADSubmit || true
      fi
    done
    if [[ "$ad_opened" != "true" ]]; then
      consecutive_fail=$((consecutive_fail + 1))
      echo "pc_round=$round rewarded ad did not open (consecutive_fail=$consecutive_fail)" | tee -a "$out/probe-status.txt"
      collect_diagnostics "pc-noopen-$round"
      if (( consecutive_fail >= 2 )); then
        echo "PC phase gave up opening ads" | tee -a "$out/probe-status.txt"
        break
      fi
      return_to_pc_page
      continue
    fi

    capture_screen "screen-pc-ad-started-$round"
    sleep 15
    capture_screen "screen-pc-ad-15s-$round"
    sleep 30
    capture_screen "screen-pc-ad-45s-$round"
    sleep 30
    capture_screen "screen-pc-ad-finished-$round"

    close_reward_ad pc || true

    verified="false"
    for poll in $(seq 1 6); do
      sleep 10
      capture_ui "screen-pc-after-$round-$poll"
      fresh="$(pc_progress "$out/screen-pc-after-$round-$poll.xml" || echo "")"
      if [[ -z "$fresh" ]]; then
        continue
      fi
      read -r after_count after_total <<< "$fresh"
      if (( after_count > pc_before )); then
        verified="true"
        pc_before="$after_count"
        pc_total="${after_total:-$pc_total}"
        break
      fi
    done
    if [[ "$verified" == "true" ]]; then
      pc_ok=$((pc_ok + 1))
      consecutive_fail=0
      echo "pc_round=$round verified progress=$pc_before/$pc_total" | tee -a "$out/probe-status.txt"
    else
      consecutive_fail=$((consecutive_fail + 1))
      echo "pc_round=$round NOT verified (consecutive_fail=$consecutive_fail)" | tee -a "$out/probe-status.txt"
      collect_diagnostics "pc-noverify-$round"
      if (( consecutive_fail >= 2 )); then
        echo "PC phase gave up after unverified rounds" | tee -a "$out/probe-status.txt"
        break
      fi
    fi
  done
fi

# --- Summary.
final_file="$out/activity-start.json"
if [[ -f "$out/activity-mobile-final.json" ]]; then
  final_file="$out/activity-mobile-final.json"
fi
watch_final="$(protocol_value "$final_file" userWatchCnt 2>/dev/null || true)"; watch_final="${watch_final:-$watch0}"
next_final="$(protocol_value "$final_file" nextVideoCnt 2>/dev/null || true)"; next_final="${next_final:-$next0}"

mobile_success="true"
if (( mobile_ads > 0 )); then
  if [[ "$next_final" != "0" ]] && (( mobile_ok < mobile_planned )); then
    mobile_success="false"
  fi
fi
pc_success="true"
if [[ "$pc_watch_enabled" == "true" ]]; then
  if (( pc_total > 0 )) && (( pc_before >= pc_total )); then
    :
  elif (( pc_ok < pc_planned )); then
    pc_success="false"
  fi
fi

{
  echo "pc_reward_page=$pc_page_reached"
  echo "button_text=$button_text"
  echo "mobile_watch_before=$watch0"
  echo "mobile_watch_after=$watch_final"
  echo "mobile_next_after=$next_final"
  echo "mobile_verified=$mobile_ok/$mobile_planned"
  echo "pc_progress_before=$pc_before"
  echo "pc_progress_after=$pc_before"
  echo "pc_progress_total=$pc_total"
  echo "pc_verified=$pc_ok/$pc_planned"
  echo "mobile_success=$mobile_success"
  echo "pc_success=$pc_success"
} | tee -a "$out/probe-status.txt"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## ETAlien reward run"
    echo ""
    echo "| Ladder | Result |"
    echo "| --- | --- |"
    echo "| Mobile (protocol) | $watch0 -> $watch_final, next=$next_final, verified $mobile_ok/$mobile_planned |"
    echo "| PC (UI x/9) | $pc_before/$pc_total, verified $pc_ok/$pc_planned |"
    echo ""
    echo '```'
    cat "$out/probe-status.txt"
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [[ "$mobile_success" != "true" || "$pc_success" != "true" ]]; then
  exit 1
fi
exit 0

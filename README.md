# ETAlien task runner

This repository contains the protocol layer for the ETAlien mobile task page.

The Android client fetches the current reward ladder from:

```text
GET /award/v1/ad/activity
```

The response is protobuf `AdActivityResponse` and includes the current watch
count, next required count, next reward, and the per-stage `videoBar` list.
The request uses the client signing scheme recovered from version 3.13.10.

## Configuration

Set these environment variables for a read-only inspection:

```text
ETALIEN_TOKEN       raw value of the Authorization header
ETALIEN_DVC         device identifier used in x-eta
ETALIEN_CHANNEL     channel value used in x-eta (default: official)
```

Run:

```text
node src/cli.mjs inspect
```

The included GitHub Actions workflow runs at approximately 09:31 Beijing time
and prints the server-provided task snapshot. GitHub schedules can be delayed.

For a fresh mobile session, the client also exposes the SMS login protocol:

```text
node src/cli.mjs login-code PHONE
node src/cli.mjs login PHONE CODE
```

For the Windows-compatible password login flow, use:

```text
node src/cli.mjs login-password PHONE PASSWORD
```

The APK-compatible SMS flow remains available with `login-code` and `login`.
The CLI masks the authorization value in normal output and saves the full
session to the ignored `.session.json` file. Deployments should store those
values in the platform secret store rather than committing the file.

The first implementation intentionally separates task discovery from ad
playback. A successful ad reward requires a valid rewarded-ad SDK callback;
the business API does not expose a direct mobile reward-submit endpoint.

## PC reward automation status

The Android client exposes a separate PC acceleration reward page under
`My games` and the computer side of the phone/computer switch. The current
daily ladder displays `0 / 9` and three reward stages worth 20, 30, and 10
minutes per completed rewarded ad.

The API 35 GitHub-hosted Android emulator can install the ARM APK through
`libndk_translation`, inject the existing session, and reach the PC reward
button. It does not currently receive playable ad inventory. The observed PC
slot `1109380` reports a failed `WMRewardAdDex` demand, Octopus error `80100`,
and a no-bid result, so the UI remains at `Advertising loading` and no reward
is credited.

The same APK was also tested in LDPlayer 14 on an Intel Windows host. It
reports `x86_64` plus `libhoudini.so`, but exposes a Qualcomm-like device
profile (`ro.hardware=qcom`, no `ro.kernel.qemu`) and a Beijing China Mobile
egress. It successfully loaded Baidu rewarded slot `bd-18180485`. Repeating
the test with the Android proxy routed through a Hong Kong HKT exit also
loaded the same slot; the page advanced from `1 / 9` to `2 / 9` and added 20
minutes. A mainland egress is therefore not a hard requirement. V2rayN's
bypass-mainland mode can still produce a DNS failure for
`amdcopen.m.umeng.com`, but it did not prevent the observed ad reward. The
stronger remaining difference is the GitHub emulator's virtual hardware,
advertising identity, and SDK adapter environment.

`build-testlab-fixtures.yml` is manual and only builds two token-free APKs for
a Firebase Test Lab physical-device probe. It does not submit a test matrix.
Run experiments only in the dedicated Firebase Spark project that is not
linked to Cloud Billing.

The Test Lab ARM virtual model `MediumPhone.arm` on Android 34 can start the
app and play a real rewarded video from an overseas cloud network. One
completed probe displayed a 4399 Game Box video and returned to the PC reward
page. Its observed `2 / 9` to `3 / 9` transition overlapped with an LDPlayer
test on the same account, so that run alone does not isolate which device
credited the reward. Later isolation attempts were stopped by Test Lab with
`Internal System Error 3` before device logs were produced.

`daily-pc-rewards.yml` submits one ARM virtual-device matrix each day at about
10:05 Beijing time. It authenticates through GitHub OIDC, builds token-free
fixtures, reads the current `x / y` progress from the app, and plays at most
nine ads while stopping as soon as the server-provided total is reached. The
matrix is submitted asynchronously so GitHub Actions does not spend minutes
waiting for the device. Test Lab infrastructure failures are not retried by
creating extra matrices on the same day.

Firebase quotas have two different units:

- Spark is limited by test-run count per project per day: 10 virtual-device
  runs and 5 physical-device runs.
- One Android test execution can be configured for up to 60 minutes on a
  virtual device or 45 minutes on a physical device. The CLI default is 15
  minutes.
- Blaze instead includes an aggregate no-cost allowance of 60 virtual-device
  minutes and 30 physical-device minutes per project per day, then charges by
  the minute.

The scheduled workflow is pinned to one Spark ARM virtual device with a
25-minute timeout and has no physical-device or paid fallback.

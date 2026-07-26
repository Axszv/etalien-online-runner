# Rewarded-ad environment comparison

Date: 2026-07-23

This comparison uses the same ETAlien APK (`3.13.10`) and the PC rewarded-ad
page. Sensitive identifiers and session values are intentionally omitted.

## Observations

| Signal | LDPlayer 14 (inventory available) | GitHub Android Emulator (no inventory) | Test Lab ARM virtual device (no inventory) |
| --- | --- | --- | --- |
| Hardware | `qcom` | `ranchu` | `ranchu` |
| Primary ABI | `x86_64` with ARM ABIs exposed | `x86_64` | `arm64-v8a` |
| Native bridge | `libhoudini.so` | `libndk_translation.so` | none |
| Build type/tags | `user/release-keys` | surface changed to `user/release-keys`; boot/vendor partitions remain `userdebug/dev-keys` | `userdebug/dev-keys` |
| QEMU surface | `ro.boot.qemu=1`, while the primary hardware surface is `qcom` | `ro.kernel.qemu=1`, `ro.boot.qemu=1` | Google emulator device (`emu64a`) |
| Telephony surface | populated SIM/operator system properties | AOSP reference radio/T-Mobile defaults | virtual-device defaults |
| OAID seen in ETAlien analytics | empty | empty or unavailable | unavailable |
| Ad result | ad button becomes ready | Octopus `80100`, no bid | GDT `102006`, `Match no ad` |

The LDPlayer app process did not have the Android `READ_PHONE_STATE` runtime
permission. Its successful inventory result therefore does not depend on the
app directly reading the configured IMEI through that permission.

## SDK evidence

The APK contains Octopus, Baidu MobAds, GDT, Kuaishou, Pangle, and other demand
adapters. The observed LDPlayer initialization reported these adapter versions:

- GDT `4.680.1550`
- Kuaishou `5.3.20.1`
- Baidu `9.4503`
- Wangmai `7.9.18.20`
- Octopus `2.6.5.7`

During initialization, the process accessed Android build-attestation
properties and LDPlayer's `/data/local/cfg-nihyg/app_device` device source. The
Kuaishou security component (`KsSecSDKWrapper`) produced an opaque encrypted
`deviceInfo` value. The APK also contains the explicit diagnostic string
`Emulator is detected, please use real phone!` and code paths for checking
`ro.kernel.qemu`, ADB/developer settings, device files, CPU information, OAID,
Android ID, and app signatures.

This means the request identity is not reducible to a fixed OAID, Android ID,
or `Build.MODEL`. The ad SDKs derive a signed or encrypted device fingerprint
from several layers that remain visibly different after a `build.prop`
overlay. The standard GitHub Emulator path is therefore closed by the stated
decision rule.

## Next execution target

`physical-arm-inventory-probe.yml` uses one Firebase Test Lab physical Pixel 5
(`redfin`, Android 11), the catalog's stable `default` physical device, and exits
after the PC ad button becomes ready. It
does not open the ad or change reward progress. The workflow is manual-only,
submits one device, and aborts before submission if Cloud Billing is enabled.
Its `original-apk-smoke` mode runs a two-minute Robo smoke test against the
unmodified APK to distinguish Test Lab infrastructure and installation failures
from failures introduced by the debuggable, re-signed instrumentation fixture.

If this probe reports `ad_ready=true`, a separate one-ad callback probe can test
rendering and reward progression without conflating inventory selection with
the reward callback. If it remains in the loading state, the cloud network or
Test Lab device policy is the remaining blocker rather than emulator identity.

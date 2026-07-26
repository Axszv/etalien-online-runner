#!/usr/bin/env bash
set -euo pipefail

apk="${1:?APK path is required}"
out="${2:-testlab-build}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

build_tools="$(find "$ANDROID_HOME/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)"
android_jar="$(find "$ANDROID_HOME/platforms" -mindepth 2 -maxdepth 2 -name android.jar | sort -V | tail -n 1)"
test_runner_jar="$(dirname "$android_jar")/optional/android.test.runner.jar"
test_base_jar="$(dirname "$android_jar")/optional/android.test.base.jar"
if [[ -z "$build_tools" || -z "$android_jar" \
    || ! -f "$test_runner_jar" || ! -f "$test_base_jar" ]]; then
  echo "Android build tools and a platform SDK are required" >&2
  exit 1
fi

apktool="$out/apktool.jar"
curl --fail --location --silent --show-error \
  https://github.com/iBotPeaches/Apktool/releases/download/v3.0.3/apktool_3.0.3.jar \
  --output "$apktool"

decoded="$out/decoded"
java -jar "$apktool" decode --force --no-src "$apk" --output "$decoded"
sed -i '0,/<application /s//<application android:debuggable="true" /' \
  "$decoded/AndroidManifest.xml"
java -jar "$apktool" build "$decoded" --output "$out/target-unaligned.apk"

keytool -genkeypair -noprompt \
  -keystore "$out/testlab.jks" -storepass android -keypass android \
  -alias testlab -keyalg RSA -keysize 2048 -validity 30 \
  -dname 'CN=ETAlien Test Lab,O=Local Test,C=CN' > /dev/null

"$build_tools/zipalign" -f 4 "$out/target-unaligned.apk" "$out/etalien-testlab.apk"
"$build_tools/apksigner" sign \
  --ks "$out/testlab.jks" --ks-pass pass:android --key-pass pass:android \
  --out "$out/etalien-testlab-signed.apk" "$out/etalien-testlab.apk"

classes="$out/test-classes"
mkdir -p "$classes" "$out/test-dex"
javac -source 8 -target 8 -encoding UTF-8 \
  -classpath "$android_jar:$test_runner_jar:$test_base_jar" -d "$classes" \
  "$root/testlab/src/com/etalien/cloudtest/Runner.java" \
  "$root/testlab/src/com/etalien/cloudtest/ProbeTest.java"
mapfile -t class_files < <(find "$classes" -type f -name '*.class')
"$build_tools/d8" --lib "$android_jar" --lib "$test_runner_jar" \
  --lib "$test_base_jar" \
  --output "$out/test-dex" "${class_files[@]}"
"$build_tools/aapt2" link \
  -I "$android_jar" --manifest "$root/testlab/AndroidManifest.xml" \
  --min-sdk-version 26 --target-sdk-version 28 \
  -o "$out/runner-unsigned.apk"
(cd "$out/test-dex" && zip -q -j "$out/runner-unsigned.apk" classes.dex)
"$build_tools/zipalign" -f 4 "$out/runner-unsigned.apk" "$out/runner-aligned.apk"
"$build_tools/apksigner" sign \
  --ks "$out/testlab.jks" --ks-pass pass:android --key-pass pass:android \
  --out "$out/etalien-cloudtest.apk" "$out/runner-aligned.apk"

"$build_tools/apksigner" verify --verbose "$out/etalien-testlab-signed.apk"
"$build_tools/apksigner" verify --verbose "$out/etalien-cloudtest.apk"

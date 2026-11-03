#!/usr/bin/env bash
# Run the app on a headless Android emulator with simulated nodes, on a Mac
# with no Android Studio. One-time setup is in the repo README (brew install
# openjdk@17 and android-commandlinetools, then sdkmanager for the packages).
#
#   tools/emulator.sh create     # make the virtual device (once)
#   tools/emulator.sh boot       # start it headless and wait for Android
#   tools/emulator.sh run        # flutter run with FAKE_NODES=true
#   tools/emulator.sh shot NAME  # save a screenshot to /tmp/NAME.png
#   tools/emulator.sh tap X Y    # tap at pixel coordinates
#   tools/emulator.sh stop
set -euo pipefail

export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
AVD=dance_pixel
IMAGE="system-images;android-35;google_apis;arm64-v8a"
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"

case "${1:-}" in
  create)
    echo no | avdmanager create avd -n "$AVD" -k "$IMAGE" -d pixel_7 --force
    # Faster boot, no animations, fixed window size.
    cfg="$HOME/.android/avd/$AVD.avd/config.ini"
    sed -i '' -e 's/^hw.keyboard=.*/hw.keyboard=yes/' "$cfg" || true
    grep -q '^hw.keyboard' "$cfg" || echo 'hw.keyboard=yes' >> "$cfg"
    echo "created $AVD"
    ;;
  boot)
    nohup emulator -avd "$AVD" -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect \
      -no-snapshot >/tmp/emulator.log 2>&1 &
    echo "emulator starting (log /tmp/emulator.log)"
    adb wait-for-device
    until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
    adb shell settings put global window_animation_scale 0
    adb shell settings put global transition_animation_scale 0
    adb shell settings put global animator_duration_scale 0
    echo "booted: $(adb devices | grep -c emulator) device(s)"
    ;;
  run)
    cd "$APP_DIR"
    flutter run -d emulator-5554 --dart-define=FAKE_NODES=true "${@:2}"
    ;;
  install)
    cd "$APP_DIR"
    flutter build apk --debug --dart-define=FAKE_NODES=true
    adb install -r build/app/outputs/flutter-apk/app-debug.apk
    adb shell am start -n com.example.dance_trainer/.MainActivity
    ;;
  shot)
    adb exec-out screencap -p > "/tmp/${2:-shot}.png"
    echo "/tmp/${2:-shot}.png"
    ;;
  tap)
    adb shell input tap "$2" "$3"
    ;;
  stop)
    adb emu kill || true
    ;;
  *)
    sed -n 2,12p "$0"
    ;;
esac

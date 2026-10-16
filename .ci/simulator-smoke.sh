#!/bin/bash
set -euo pipefail

test -n "${CI_ROOT:-}"
runtime="$(xcrun simctl list -j runtimes | python3 -c 'import json,sys; r=[x["identifier"] for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and x.get("platform") == "tvOS" and x.get("version") == "27.0"]; assert len(r) == 1, r; print(r[0])')"
device_type="$(xcrun simctl list -j devicetypes | python3 -c 'import json,sys; d=[x["identifier"] for x in json.load(sys.stdin)["devicetypes"] if x["name"] == "Apple TV 4K (3rd generation)"]; assert len(d) == 1, d; print(d[0])')"
device="$(xcrun simctl create "SharkParty CI ${GITHUB_RUN_ID:-local}" "$device_type" "$runtime")"
cleanup() {
  xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
  xcrun simctl delete "$device" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
app="$CI_ROOT/DerivedData/Build/Products/Debug-appletvsimulator/SharkParty.app"
xcrun simctl install "$device" "$app"
xcrun simctl launch "$device" org.deadfin.SharkParty
sleep 5
xcrun simctl io "$device" screenshot "$CI_ROOT/simulator-screen.png"
xcrun simctl spawn "$device" log show --last 2m --style compact --predicate 'process == "SharkParty"' > "$CI_ROOT/simulator.log" 2>&1 || true
test -s "$CI_ROOT/simulator-screen.png"

xcodebuild -project Swiftfin.xcodeproj -scheme 'SharkParty tvOS' \
  -configuration Debug -destination "platform=tvOS Simulator,id=$device" \
  -derivedDataPath "$CI_ROOT/DerivedData" \
  -resultBundlePath "$CI_ROOT/Session-tests.xcresult" \
  -only-testing:SharkPartySessionTests \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES test > "$CI_ROOT/session-tests.log" 2>&1 || {
    tail -100 "$CI_ROOT/session-tests.log"
    exit 1
  }
xcrun xcresulttool get test-results summary --path "$CI_ROOT/Session-tests.xcresult" \
  | python3 -c 'import json,sys; s=json.load(sys.stdin); print("Session XCTest: {passedTests} passed, {failedTests} failed".format(**s)); assert s["totalTestCount"] == s["passedTests"] == 3 and s["failedTests"] == 0, s'
git diff --exit-code
test -z "$(git ls-files --others --exclude-standard)"

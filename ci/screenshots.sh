#!/bin/bash
# Build per simulatore, screenshot delle schermate principali e verifiche nell'app (ALS-SELFTEST).
set -uo pipefail
OUT=ci-out/screens; mkdir -p "$OUT"
xcodebuild -project AudiLightStudio.xcodeproj -scheme AudiLightStudio -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/sim CODE_SIGNING_ALLOWED=NO build > ci-out/sim-build.log 2>&1
echo "build simulatore: $?"; tail -3 ci-out/sim-build.log
APP=$(find build/sim/Build/Products/Debug-iphonesimulator -maxdepth 1 -name "*.app" | head -1)
test -n "$APP" || { echo "app per simulatore non trovata"; exit 1; }
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]; best=None
for rt,devs in d.items():
    if "iOS" not in rt: continue
    for x in devs:
        n=x["name"]
        if n.startswith("iPhone") and "Pro" in n and "Max" not in n:
            best=(rt,x["udid"],n) if best is None or rt>best[0] else best
print(best[1] if best else "")')
test -n "$UDID" || { echo "nessun simulatore iPhone"; exit 1; }
xcrun simctl list devices | grep "$UDID"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time 10:24 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$UDID" "$APP"
BID=$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist")
shot() { local name=$1 wait=$2; shift 2
  xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
  xcrun simctl launch "$UDID" "$BID" "$@" >/dev/null
  sleep "$wait"
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null && echo "screenshot $name"
}
shot 01-studio 12 -ALSSeedDemo -ALSScreen studio -ALSPlay ice_scan
shot 02-studio-inspector 8 -ALSScreen studio -ALSPlay ice_scan -ALSSelect B:57:left
shot 03-studio-zone 8 -ALSScreen studio -ALSStudioMode map -ALSSelect B:57:right
shot 04-mappa3d-modifica-zone 9 -ALSScreen map3D -ALSZoneMode
shot 05-centraline 6 -ALSScreen controllers
shot 06-altro 5 -ALSScreen more
shot 06b-impostazioni 8 -ALSScreen more -ALSPushSettings
shot 06c-mappa3d 9 -ALSScreen map3D
shot 06b-impostazioni 8 -ALSScreen more -ALSPushSettings
shot 06c-mappa3d 9 -ALSScreen map3D
# Verifiche nell'app vera
xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1 || true
xcrun simctl launch --console-pty "$UDID" "$BID" -ALSScreen studio -ALSSelfTest > ci-out/selftest-console.log 2>&1 &
LP=$!
sleep 25
xcrun simctl io "$UDID" screenshot "$OUT/07-dopo-verifiche.png" >/dev/null || true
kill $LP 2>/dev/null || true
DATA=$(xcrun simctl get_app_container "$UDID" "$BID" data)
cp "$DATA/Documents/selftest.txt" ci-out/selftest.txt 2>/dev/null || grep "ALS-SELFTEST" ci-out/selftest-console.log > ci-out/selftest.txt || true
cat ci-out/selftest.txt || true
shot 08-mappa3d-scansione-parziale 10 -ALSScreen map3D -ALSPartialScan
ls -la "$OUT"

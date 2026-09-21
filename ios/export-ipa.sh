#!/usr/bin/env bash
# Собрать ipa для Self Store одной командой: архив + экспорт Release Testing (ad hoc).
# Использование: ./export-ipa.sh [папка_вывода]   → <папка>/Stamps.ipa
# Подпись — автоматическая по Config.xcconfig (DEVELOPMENT_TEAM); сервер стора её всё равно переделает.
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-$HOME/Desktop/StampsExport}"
ARCHIVE="$(mktemp -d)/Stamps.xcarchive"

if [ ! -d CountryCounter.xcodeproj ]; then xcodegen generate >/dev/null; fi

echo "→ archive"
xcodebuild -project CountryCounter.xcodeproj -scheme CountryCounter -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates archive -quiet

PLIST="$(mktemp).plist"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>release-testing</string>
  <key>signingStyle</key><string>automatic</string>
  <key>compileBitcode</key><false/>
  <key>stripSwiftSymbols</key><true/>
  <key>thinning</key><string>&lt;none&gt;</string>
</dict></plist>
PL

echo "→ export"
mkdir -p "$OUT"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$PLIST" -exportPath "$OUT" -allowProvisioningUpdates -quiet
rm -rf "$(dirname "$ARCHIVE")" "$PLIST"
IPA="$(ls "$OUT"/*.ipa | head -1)"
echo "✓ $IPA ($(du -h "$IPA" | cut -f1))"

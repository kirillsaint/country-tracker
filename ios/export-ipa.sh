#!/usr/bin/env bash
# Собрать ipa для Self Store одной командой: архив + экспорт Release Testing (ad hoc).
# Использование: ./export-ipa.sh [--bump major|minor|patch|build] [папка_вывода]   → <папка>/Stamps.ipa
#   --bump patch  0.1.1 (2) → 0.1.2 (3): версия по типу обновления, номер сборки всегда +1
#   --bump build  только номер сборки
# Версия правится в project.yml (приложение и виджет одинаково), проект перегенерируется xcodegen.
# Подпись — автоматическая по Config.xcconfig (DEVELOPMENT_TEAM); сервер стора её всё равно переделает.
set -euo pipefail
cd "$(dirname "$0")"

BUMP=""
OUT="$HOME/Desktop/StampsExport"
while [ $# -gt 0 ]; do
  case "$1" in
    --bump) BUMP="${2:-}"; shift 2 ;;
    --bump=*) BUMP="${1#--bump=}"; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) OUT="$1"; shift ;;
  esac
done

if [ -n "$BUMP" ]; then
  VERSION="$(grep -m1 'CFBundleShortVersionString:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
  BUILD="$(grep -m1 'CFBundleVersion:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')"
  # у приложения и виджета версии обязаны совпадать, иначе Apple отклонит сборку, а bump поменяет только одну
  if [ "$(grep -c "CFBundleShortVersionString: \"$VERSION\"" project.yml)" != 2 ] || [ "$(grep -c "CFBundleVersion: \"$BUILD\"" project.yml)" != 2 ]; then
    echo "project.yml: версии приложения и виджета расходятся — выровняйте их руками:" >&2
    grep -n 'CFBundleShortVersionString:\|CFBundleVersion:' project.yml >&2
    exit 2
  fi
  IFS=. read -r MAJOR MINOR PATCH <<<"$VERSION"
  case "$BUMP" in
    major) NEW_VERSION="$((MAJOR + 1)).0.0" ;;
    minor) NEW_VERSION="$MAJOR.$((MINOR + 1)).0" ;;
    patch) NEW_VERSION="$MAJOR.$MINOR.$((${PATCH:-0} + 1))" ;;
    build) NEW_VERSION="$VERSION" ;;
    *) echo "--bump: ожидается major, minor, patch или build" >&2; exit 2 ;;
  esac
  NEW_BUILD="$((BUILD + 1))"
  # обе цели (приложение и виджет) — версии обязаны совпадать
  sed -i '' -e "s/CFBundleShortVersionString: \"$VERSION\"/CFBundleShortVersionString: \"$NEW_VERSION\"/g" \
            -e "s/CFBundleVersion: \"$BUILD\"/CFBundleVersion: \"$NEW_BUILD\"/g" project.yml
  xcodegen generate >/dev/null
  echo "→ версия $VERSION ($BUILD) → $NEW_VERSION ($NEW_BUILD); не забудьте закоммитить project.yml и Info.plist"
fi

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

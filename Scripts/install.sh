#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
app_name="Aura.app"
destination="/Applications/$app_name"
staging="$repo_root/.build/$app_name"
signing_identity="${AURA_SIGNING_IDENTITY:-Apple Development: kalenj@gmail.com (85P549P8K8)}"

cd "$repo_root"
swift build -c release

rm -rf "$staging"
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
cp ".build/release/Aura" "$staging/Contents/MacOS/Aura"
cp "Resources/Info.plist" "$staging/Contents/Info.plist"
cp "Resources/Aura.icns" "$staging/Contents/Resources/Aura.icns"

codesign --force --deep --sign "$signing_identity" "$staging"

/usr/bin/pkill -x Aura 2>/dev/null || true

if [[ -d "$destination" ]]; then
    rm -rf "$destination"
fi
ditto "$staging" "$destination"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
open "$destination"

echo "Installed $destination"

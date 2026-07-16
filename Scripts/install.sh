#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
app_name="Aura.app"
destination="/Applications/$app_name"
staging="$repo_root/.build/$app_name"

cd "$repo_root"
swift build -c release

rm -rf "$staging"
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
cp ".build/release/Aura" "$staging/Contents/MacOS/Aura"
cp "Resources/Info.plist" "$staging/Contents/Info.plist"
cp "Resources/Aura.icns" "$staging/Contents/Resources/Aura.icns"

codesign --force --deep --sign - "$staging"

if [[ -d "$destination" ]]; then
    rm -rf "$destination"
fi
ditto "$staging" "$destination"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
open "$destination"

echo "Installed $destination"

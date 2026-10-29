#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."

package_root="$PWD"
output_dir="$package_root/dist"
output_file="$output_dir/ChatGPT-Proxy.dmg"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [[ -e "$output_file" ]]; then
    echo "DMG already exists: $output_file" >&2
    exit 1
fi

package_parent="${TMPDIR:-/private/tmp}"
package_temp=$(mktemp -d "${package_parent%/}/chatgpt-proxy.XXXXXX")
built_app="$package_temp/DerivedData/Build/Products/Release/ChatGPT Proxy.app"
stage_app="$package_temp/stage/ChatGPT Proxy.app"
verified_image="$package_temp/ChatGPT-Proxy.dmg"
mount_dir="$package_temp/mount"
mounted=0

cleanup() {
    if [[ "$mounted" == 1 ]]; then
        "$lsregister" -u "$mount_dir/ChatGPT Proxy.app" >/dev/null 2>&1 || true
        hdiutil detach "$mount_dir" -quiet || true
    fi
    for app in "$built_app" "$stage_app"; do
        if [[ -d "$app" ]]; then
            "$lsregister" -u "$app" >/dev/null 2>&1 || true
        fi
    done
    rm -rf -- "$package_temp"
}
trap cleanup EXIT

# 临时目录构建，结束后清理，避免产生额外的应用启动入口。
xcodebuild -quiet -project ChatGPTProxy.xcodeproj -scheme ChatGPTProxy \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$package_temp/DerivedData" CODE_SIGN_IDENTITY=- \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
    REGISTER_APP_WITH_LAUNCH_SERVICES=NO build

mkdir -p "$output_dir" "$package_temp/stage" "$mount_dir"
ditto "$built_app" "$stage_app"

# 移除与使用无关的构建机器元数据，再以本地临时签名封装。
python3 - "$stage_app" <<'PY'
import plistlib
import sys
from pathlib import Path
app = Path(sys.argv[1])
path = app/'Contents/Info.plist'
info = plistlib.loads(path.read_bytes())
info.pop('BuildMachineOSBuild', None)
path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
assert info['CFBundleIdentifier'] == 'org.codex-gui-proxy.ChatGPTProxy'
assert info['CFBundleIconFile'] == 'AppIcon'
for p in app.rglob('*'):
    if p.is_file():
        data = p.read_bytes()
        assert b'/Users/' not in data, p
PY
codesign --force --sign - --options runtime --timestamp=none "$stage_app"
codesign --verify --deep --strict "$stage_app"
ln -s /Applications "$package_temp/stage/Applications"

hdiutil create -volname 'ChatGPT Proxy' -srcfolder "$package_temp/stage" \
    -fs HFS+ -format UDZO "$verified_image"
hdiutil verify "$verified_image"
hdiutil attach "$verified_image" -readonly -nobrowse -mountpoint "$mount_dir" -quiet
mounted=1

python3 - "$mount_dir" "$package_root/LICENSE" <<'PY'
import plistlib
import subprocess
import sys
from pathlib import Path
root = Path(sys.argv[1])
assert {p.name for p in root.iterdir()} == {'ChatGPT Proxy.app', 'Applications'}
assert (root/'Applications').is_symlink()
assert (root/'Applications').readlink() == Path('/Applications')
app = root/'ChatGPT Proxy.app'
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'org.codex-gui-proxy.ChatGPTProxy'
assert 'BuildMachineOSBuild' not in info
binary = app/'Contents/MacOS'/info['CFBundleExecutable']
architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
assert set(architectures) == {'arm64', 'x86_64'}, architectures
assert (app/'Contents/Resources/LICENSE').read_bytes() == Path(sys.argv[2]).read_bytes()
for name in ['AppIcon.icns', 'Assets.car']:
    assert (app/'Contents/Resources'/name).is_file()
for p in app.rglob('*'):
    if p.is_file():
        assert b'/Users/' not in p.read_bytes(), p
print('Verified DMG layout, application resources, license and bundle path scan.')
print('Application version:', info['CFBundleShortVersionString'])
print('Architectures:', ' '.join(architectures))
PY
codesign --verify --deep --strict "$mount_dir/ChatGPT Proxy.app"
"$lsregister" -u "$mount_dir/ChatGPT Proxy.app" >/dev/null 2>&1 || true
hdiutil detach "$mount_dir" -quiet
mounted=0
# 验证全部通过后再输出，失败时不留下看似可安装的镜像。
if [[ -e "$output_file" ]]; then
    echo "DMG already exists: $output_file" >&2
    exit 1
fi
mv -n "$verified_image" "$output_file"
shasum -a 256 "$output_file"
echo "Created: $output_file"

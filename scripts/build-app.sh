#!/bin/zsh
# Воспроизводимая сборка: исходники и версия отделены от генерируемого .app.
set -euo pipefail
cd "${0:A:h}/.."
version="$(<VERSION)"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Некорректный VERSION'; exit 1; }
[[ -f Assets/AppIcon.png ]] || { print -u2 'Не найден Assets/AppIcon.png'; exit 1; }

# Полный Xcode поддерживает SwiftPM; Command Line Tools может не иметь PlatformPath.
if xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; then
    swift build -c release
    build_dir="$(swift build -c release --show-bin-path)"
else
    print 'Сборка штатным компилятором Swift (Command Line Tools).'
    build_dir="$PWD/.build/native"
    module_cache="${VIBEWAVE_MODULE_CACHE:-$build_dir/Modules}"
    mkdir -p "$build_dir"
    swiftc -O -parse-as-library -emit-module -module-name VibeWaveCore \
        Sources/VibeWaveCore/Library.swift -emit-module-path "$build_dir/VibeWaveCore.swiftmodule" \
        -module-cache-path "$module_cache" -target "$(uname -m)-apple-macosx13.0"
    swiftc -O -parse-as-library -c -module-name VibeWaveCore \
        Sources/VibeWaveCore/Library.swift -module-cache-path "$module_cache" \
        -target "$(uname -m)-apple-macosx13.0" -o "$build_dir/VibeWaveCore.o"
    swiftc -O -parse-as-library -I "$build_dir" -module-cache-path "$module_cache" \
        -target "$(uname -m)-apple-macosx13.0" \
        Sources/VibeWave/*.swift "$build_dir/VibeWaveCore.o" -o "$build_dir/VibeWave"
fi

# Собираем в отдельном каталоге, чтобы не оставлять старые ресурсы в новой подписи.
mkdir -p dist
staging="$(mktemp -d "$PWD/dist/.VibeWave-build.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
app_dir="$staging/VibeWave.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/VibeWave" "$app_dir/Contents/MacOS/VibeWave"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app_dir/Contents/Info.plist"

iconset="$build_dir/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app_dir/Contents/Resources/VibeWaveIcon.icns"
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"

# Удаляется только заменённая сгенерированная сборка, а не исходники или музыка.
if [[ -e dist/VibeWave.app ]]; then mv dist/VibeWave.app "$staging/previous.app"; fi
mv "$app_dir" dist/VibeWave.app
print -r -- "Готово: $PWD/dist/VibeWave.app ($version)"

#!/bin/zsh
# Воспроизводимая сборка: исходники и версия отделены от генерируемого .app.
# По умолчанию собирается универсальное приложение (Apple Silicon + Intel).
# Только текущая архитектура для быстрой отладки: VIBEWAVE_ARCHS="$(uname -m)" zsh scripts/build-app.sh
set -euo pipefail
cd "${0:A:h}/.."
version="$(<VERSION)"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Некорректный VERSION'; exit 1; }
[[ -f Assets/AppIcon.png ]] || { print -u2 'Не найден Assets/AppIcon.png'; exit 1; }
archs=(${=VIBEWAVE_ARCHS:-arm64 x86_64})
for arch in $archs; do
    [[ "$arch" == arm64 || "$arch" == x86_64 ]] || { print -u2 "Неизвестная архитектура: $arch"; exit 1; }
done

# Каждая архитектура собирается отдельно, затем срезы объединяются через lipo.
binaries=()
if xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; then
    # Полный Xcode: SwiftPM для каждой архитектуры. Новые версии SwiftPM кладут
    # результат разных архитектур в один каталог, поэтому срез сразу копируется.
    for arch in $archs; do
        print -r -- "Сборка SwiftPM: $arch"
        swift build -c release --triple "$arch-apple-macosx13.0"
        slice="$PWD/.build/slices/$arch/VibeWave"
        mkdir -p "${slice:h}"
        cp "$(swift build -c release --triple "$arch-apple-macosx13.0" --show-bin-path)/VibeWave" "$slice"
        [[ "$(lipo -archs "$slice")" == "$arch" ]] || { print -u2 "Срез $arch собран не для $arch"; exit 1; }
        binaries+=("$slice")
    done
else
    # Command Line Tools может не иметь PlatformPath: компилируем напрямую.
    print 'Сборка штатным компилятором Swift (Command Line Tools).'
    core_sources=(Sources/VibeWaveCore/*.swift)
    for arch in $archs; do
        print -r -- "Сборка swiftc: $arch"
        arch_dir="$PWD/.build/native/$arch"
        module_cache="${VIBEWAVE_MODULE_CACHE:-$PWD/.build/native/Modules}/$arch"
        target="$arch-apple-macosx13.0"
        mkdir -p "$arch_dir"
        swiftc -O -parse-as-library -emit-module -module-name VibeWaveCore \
            $core_sources -emit-module-path "$arch_dir/VibeWaveCore.swiftmodule" \
            -module-cache-path "$module_cache" -target "$target"
        swiftc -O -parse-as-library -c -wmo -module-name VibeWaveCore \
            $core_sources -module-cache-path "$module_cache" \
            -target "$target" -o "$arch_dir/VibeWaveCore.o"
        swiftc -O -parse-as-library -I "$arch_dir" -module-cache-path "$module_cache" \
            -target "$target" \
            Sources/VibeWave/*.swift "$arch_dir/VibeWaveCore.o" -o "$arch_dir/VibeWave"
        binaries+=("$arch_dir/VibeWave")
    done
fi

# Собираем в отдельном каталоге, чтобы не оставлять старые ресурсы в новой подписи.
mkdir -p dist
staging="$(mktemp -d "$PWD/dist/.VibeWave-build.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
app_dir="$staging/VibeWave.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
lipo -create $binaries -output "$app_dir/Contents/MacOS/VibeWave"
built_archs="$(lipo -archs "$app_dir/Contents/MacOS/VibeWave")"
for arch in $archs; do
    [[ " $built_archs " == *" $arch "* ]] || { print -u2 "В исполняемом файле нет среза $arch"; exit 1; }
done
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app_dir/Contents/Info.plist"

iconset="$staging/AppIcon.iconset"
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
print -r -- "Готово: $PWD/dist/VibeWave.app ($version, $built_archs)"

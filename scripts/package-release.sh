#!/bin/zsh
# Упаковка уже проверенной сборки в установщики без загрузки на внешние сервисы:
#   VibeWave-<версия>-macos-<arch>.dmg  — образ диска: перетащить VibeWave в «Программы»;
#   VibeWave-<версия>-macos-<arch>.pkg  — мастер установки в /Applications;
#   VibeWave-<версия>-macos-<arch>.zip  — архив приложения;
#   SHA256SUMS.txt                      — контрольные суммы.
# <arch> — universal для Apple Silicon + Intel, иначе имя единственной архитектуры.
# Подпись ad hoc: это не Developer ID и не нотариализация.
set -euo pipefail
cd "${0:A:h}/.."
version="$(<VERSION)"
app_dir="$PWD/dist/VibeWave.app"
[[ -d "$app_dir" ]] || { print -u2 'Сначала запустите scripts/build-app.sh'; exit 1; }
built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
[[ "$built_version" == "$version" ]] || { print -u2 'Версия .app отличается от VERSION'; exit 1; }
codesign --verify --strict "$app_dir"

archs=(${(s: :)"$(lipo -archs "$app_dir/Contents/MacOS/VibeWave")"})
if (( ${archs[(Ie)arm64]} && ${archs[(Ie)x86_64]} )); then
    platform=universal
elif (( ${#archs} == 1 )) && [[ "${archs[1]}" == arm64 || "${archs[1]}" == x86_64 ]]; then
    platform="${archs[1]}"
else
    print -u2 "Архитектуры не поддерживаются: ${archs[*]}"
    exit 1
fi

# Отдельный каталог на версию и платформу: прежние релизы и их суммы не перезаписываются.
output_dir="${1:-$PWD/.release/v$version-$platform}"
mkdir -p "$output_dir"
output_dir="${output_dir:A}"
base="VibeWave-${version}-macos-${platform}"
for asset in "$base.dmg" "$base.pkg" "$base.zip" SHA256SUMS.txt; do
    [[ ! -e "$output_dir/$asset" ]] || { print -u2 "$asset уже существует; используйте отдельный выходной каталог"; exit 1; }
done

work="$(mktemp -d "${TMPDIR:-/tmp}/vibewave-package.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

# DMG: приложение и ссылка на «Программы» для установки перетаскиванием.
dmg_root="$work/dmg"
mkdir -p "$dmg_root"
ditto "$app_dir" "$dmg_root/VibeWave.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create -quiet -volname "VibeWave $version" -srcfolder "$dmg_root" -fs HFS+ -format UDZO \
    -imagekey zlib-level=9 "$output_dir/$base.dmg"
hdiutil verify -quiet "$output_dir/$base.dmg"

# PKG: установка в /Applications. Перемещение пакета отключено, чтобы установщик
# не обновлял вместо этого другую копию VibeWave, найденную в другом месте диска.
pkg_root="$work/pkg"
mkdir -p "$pkg_root"
ditto "$app_dir" "$pkg_root/VibeWave.app"
pkgbuild --quiet --analyze --root "$pkg_root" "$work/components.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$work/components.plist"
pkgbuild --quiet --root "$pkg_root" --component-plist "$work/components.plist" \
    --identifier local.vibewave.player.pkg --version "$version" \
    --install-location /Applications "$work/VibeWave-component.pkg"
cat > "$work/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>VibeWave $version</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <volume-check><allowed-os-versions><os-version min="13.0"/></allowed-os-versions></volume-check>
    <choices-outline><line choice="default"><line choice="local.vibewave.player.pkg"/></line></choices-outline>
    <choice id="default"/>
    <choice id="local.vibewave.player.pkg" visible="false"><pkg-ref id="local.vibewave.player.pkg"/></choice>
    <pkg-ref id="local.vibewave.player.pkg" version="$version" onConclusion="none">VibeWave-component.pkg</pkg-ref>
</installer-gui-script>
XML
productbuild --quiet --distribution "$work/distribution.xml" --package-path "$work" "$output_dir/$base.pkg"

ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$output_dir/$base.zip"
(
    cd "$output_dir"
    LC_ALL=C shasum -a 256 "$base.dmg" "$base.pkg" "$base.zip" > SHA256SUMS.txt
)
print -r -- "Установщики ($platform: ${archs[*]}): $output_dir"

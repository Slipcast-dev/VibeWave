#!/bin/zsh
# Упаковка уже проверенной сборки в установщики без загрузки на внешние сервисы:
#   VibeWave-<версия>-macos-<arch>.dmg  — образ диска: перетащить VibeWave в «Программы»;
#   VibeWave-<версия>-macos-<arch>.pkg  — мастер установки в /Applications;
#   VibeWave-<версия>-macos-<arch>.zip  — архив приложения;
#   SHA256SUMS.txt                      — контрольные суммы;
#   update.json                         — описание обновления для автообновления (версия, адрес ZIP,
#                                         SHA-256 и подпись Ed25519 ключом ~/.config/vibewave/update-signing-key).
# Без ключа подписи update.json не создаётся (например, в CI); VIBEWAVE_REQUIRE_UPDATE_SIGNATURE=1 делает это ошибкой.
# Заметки к обновлению: VIBEWAVE_UPDATE_NOTES_RU и VIBEWAVE_UPDATE_NOTES_EN (необязательно).
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
for asset in "$base.dmg" "$base.pkg" "$base.zip" SHA256SUMS.txt update.json; do
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
# После установки приложение передаётся пользователю, вошедшему в систему: тогда автообновление
# заменяет его без пароля администратора.
pkg_root="$work/pkg"
mkdir -p "$pkg_root" "$work/pkg-scripts"
ditto "$app_dir" "$pkg_root/VibeWave.app"
cat > "$work/pkg-scripts/postinstall" <<'SH'
#!/bin/sh
app="${3%/}/Applications/VibeWave.app"
user=$(/usr/bin/stat -f %Su /dev/console)
if [ -d "$app" ] && [ -n "$user" ] && [ "$user" != "root" ]; then
    /usr/sbin/chown -R "$user" "$app"
fi
exit 0
SH
chmod 755 "$work/pkg-scripts/postinstall"
pkgbuild --quiet --analyze --root "$pkg_root" "$work/components.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$work/components.plist"
pkgbuild --quiet --root "$pkg_root" --component-plist "$work/components.plist" \
    --scripts "$work/pkg-scripts" \
    --identifier local.vibewave.player.pkg --version "$version" \
    --install-location /Applications "$work/VibeWave-component.pkg"
cat > "$work/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>VibeWave $version</title>
    <options customize="never" require-scripts="true" hostArchitectures="arm64,x86_64"/>
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

# update.json: подписанное описание обновления. Открытый ключ в собранном приложении должен
# соответствовать закрытому ключу, иначе установленные копии отвергнут обновление.
key_file="${VIBEWAVE_UPDATE_KEY:-$HOME/.config/vibewave/update-signing-key}"
if [[ -f "$key_file" ]]; then
    tools="$PWD/.build/tools"
    target="$(uname -m)-apple-macosx13.0"
    mkdir -p "$tools"
    swiftc -parse-as-library -emit-module -module-name VibeWaveCore Sources/VibeWaveCore/*.swift \
        -emit-module-path "$tools/VibeWaveCore.swiftmodule" -module-cache-path "$tools/Modules" -target "$target"
    swiftc -parse-as-library -c -wmo -module-name VibeWaveCore Sources/VibeWaveCore/*.swift \
        -o "$tools/VibeWaveCore.o" -module-cache-path "$tools/Modules" -target "$target"
    swiftc -O -parse-as-library -I "$tools" -module-cache-path "$tools/Modules" -target "$target" \
        scripts/tools/UpdateSigner.swift "$tools/VibeWaveCore.o" -o "$tools/update-signer"
    app_key="$(/usr/libexec/PlistBuddy -c 'Print :VWUpdatePublicKey' "$app_dir/Contents/Info.plist")"
    [[ "$(VIBEWAVE_UPDATE_KEY="$key_file" "$tools/update-signer" public)" == "$app_key" ]] ||
        { print -u2 'Ключ подписи не соответствует VWUpdatePublicKey в приложении'; exit 1; }
    repo="${VIBEWAVE_REPO:-Slipcast-dev/VibeWave}"
    VIBEWAVE_UPDATE_KEY="$key_file" "$tools/update-signer" manifest "$output_dir/$base.zip" "$version" \
        "https://github.com/$repo/releases/download/v$version/$base.zip" \
        "${VIBEWAVE_UPDATE_NOTES_RU:-}" "${VIBEWAVE_UPDATE_NOTES_EN:-}" > "$output_dir/update.json"
    print -r -- "update.json подписан ключом $key_file"
elif [[ "${VIBEWAVE_REQUIRE_UPDATE_SIGNATURE:-0}" == 1 ]]; then
    print -u2 "Нет ключа подписи обновлений: $key_file"
    exit 1
else
    print -u2 'Ключа подписи нет: update.json не создан (автообновление этот выпуск не увидит).'
fi
print -r -- "Установщики ($platform: ${archs[*]}): $output_dir"

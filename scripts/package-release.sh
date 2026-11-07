#!/bin/zsh
# Упаковка уже проверенной локальной сборки без загрузки на внешние сервисы.
set -euo pipefail
cd "${0:A:h}/.."
version="$(<VERSION)"
app_dir="$PWD/dist/VibeWave.app"
[[ -d "$app_dir" ]] || { print -u2 'Сначала запустите scripts/build-app.sh'; exit 1; }
built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
[[ "$built_version" == "$version" ]] || { print -u2 'Версия .app отличается от VERSION'; exit 1; }
architecture="$(lipo -archs "$app_dir/Contents/MacOS/VibeWave")"
[[ "$architecture" == x86_64 || "$architecture" == arm64 ]] || { print -u2 'Архитектуру нужно обработать отдельно'; exit 1; }
codesign --verify --strict "$app_dir"
output_dir="${1:-$PWD/.release}"
mkdir -p "$output_dir"
output_dir="${output_dir:A}"
asset="VibeWave-${version}-macos-${architecture}.zip"
[[ ! -e "$output_dir/$asset" ]] || { print -u2 'Архив уже существует; используйте отдельный выходной каталог'; exit 1; }
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$output_dir/$asset"
(
    cd "$output_dir"
    LC_ALL=C shasum -a 256 "$asset" > SHA256SUMS.txt
)
print -r -- "Артефакты релиза: $output_dir"

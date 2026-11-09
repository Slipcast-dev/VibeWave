#!/bin/zsh
# Регрессионные проверки без установки полного Xcode.
# Компилирует все рабочие исходники; точку входа приложения заменяет Checks/RegressionChecks.swift.
# Другая архитектура (Intel-срез на Apple Silicon через Rosetta): VIBEWAVE_CHECK_ARCH=x86_64 zsh scripts/check.sh
set -euo pipefail
cd "${0:A:h}/.."
check_arch="${VIBEWAVE_CHECK_ARCH:-$(uname -m)}"
[[ "$check_arch" == arm64 || "$check_arch" == x86_64 ]] || { print -u2 "Неизвестная архитектура: $check_arch"; exit 1; }
build_dir="$PWD/.build/checks/$check_arch"
module_cache="${VIBEWAVE_MODULE_CACHE:-$PWD/.build/checks/Modules}/$check_arch"
target="$check_arch-apple-macosx13.0"
core_sources=(Sources/VibeWaveCore/*.swift)
app_sources=(Sources/VibeWave/*.swift)
app_sources=(${app_sources:#*/VibeWaveApp.swift})
mkdir -p "$build_dir"
swiftc -parse-as-library -emit-module -module-name VibeWaveCore \
    $core_sources -emit-module-path "$build_dir/VibeWaveCore.swiftmodule" \
    -module-cache-path "$module_cache" -target "$target"
swiftc -parse-as-library -c -wmo -module-name VibeWaveCore \
    $core_sources -o "$build_dir/VibeWaveCore.o" \
    -module-cache-path "$module_cache" -target "$target"
swiftc -parse-as-library -I "$build_dir" -module-cache-path "$module_cache" -target "$target" \
    $app_sources Checks/RegressionChecks.swift "$build_dir/VibeWaveCore.o" -o "$build_dir/checks"
# Путь к .app необязателен: без сборки проверка иконки пропускается.
app_bundle="$PWD/dist/VibeWave.app"
print -r -- "Регрессионные проверки: $check_arch"
if [[ -d "$app_bundle" ]]; then
    arch "-$check_arch" "$build_dir/checks" "$PWD/Checks/Fixtures" "$app_bundle"
else
    arch "-$check_arch" "$build_dir/checks" "$PWD/Checks/Fixtures"
fi

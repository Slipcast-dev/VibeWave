#!/bin/zsh
# Регрессионные проверки без установки полного Xcode.
set -euo pipefail
cd "${0:A:h}/.."
build_dir="$PWD/.build/checks"
module_cache="${VIBEWAVE_MODULE_CACHE:-$build_dir/Modules}"
mkdir -p "$build_dir"
swiftc -parse-as-library -emit-module -module-name VibeWaveCore \
    Sources/VibeWaveCore/Library.swift -emit-module-path "$build_dir/VibeWaveCore.swiftmodule" \
    -module-cache-path "$module_cache" -target "$(uname -m)-apple-macosx13.0"
swiftc -parse-as-library -c -module-name VibeWaveCore \
    Sources/VibeWaveCore/Library.swift -o "$build_dir/VibeWaveCore.o" \
    -module-cache-path "$module_cache" -target "$(uname -m)-apple-macosx13.0"
swiftc -parse-as-library -I "$build_dir" -module-cache-path "$module_cache" \
    -target "$(uname -m)-apple-macosx13.0" Sources/VibeWave/PlayerModel.swift Sources/VibeWave/TrackDropDelegate.swift \
    Sources/VibeWave/Theme.swift Sources/VibeWave/RetroControls.swift Sources/VibeWave/TrackRow.swift \
    Sources/VibeWave/ContentView.swift Sources/VibeWave/RetroWindow.swift Sources/VibeWave/TrackTable.swift \
    Sources/VibeWave/ClassicPlayer.swift \
    Checks/RegressionChecks.swift "$build_dir/VibeWaveCore.o" -o "$build_dir/checks"
"$build_dir/checks" "$PWD/Checks/Fixtures" "$PWD/dist/VibeWave.app"

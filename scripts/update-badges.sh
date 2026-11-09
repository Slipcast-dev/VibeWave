#!/bin/zsh
# Перерисовывает значки README в docs/assets/badges/ в стиле Windows 95.
# Информационные значки берут данные из проекта (VERSION), значки звёзд и скачиваний —
# из GitHub API через gh; числа фиксируются в момент запуска скрипта (например, при релизе).
# Готовые счётчики вроде shields.io не подходят: они суммируют все файлы релизов, включая
# update.json, который каждая копия VibeWave читает при запуске, и SHA256SUMS.txt.
# Без доступа к GitHub прежние значки звёзд и скачиваний остаются без изменений.
set -euo pipefail
cd "${0:A:h}/.."
repo="${VIBEWAVE_REPO:-Slipcast-dev/VibeWave}"
version="$(<VERSION)"
out="docs/assets/badges"
mkdir -p "$out"

# Ширина текста оценивается по числу символов (Arial 11 px, полужирный).
badge() {
    local file="$1" label="$2" value="$3"
    local label_width=$(( ${#label} * 7 + 16 )) value_width=$(( ${#value} * 7 + 16 ))
    local width=$(( label_width + value_width ))
    cat > "$out/$file" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="22" viewBox="0 0 $width 22" role="img" aria-label="$label: $value">
  <title>$label: $value</title>
  <rect width="$width" height="22" fill="#c0c0c0"/>
  <path d="M1 21V1H$(( width - 1 ))" fill="none" stroke="#fff" stroke-width="2"/>
  <path d="M$(( width - 1 )) 1V21H1" fill="none" stroke="#404040" stroke-width="2"/>
  <rect x="$label_width" y="3" width="$(( value_width - 5 ))" height="16" fill="#000080"/>
  <g font-family="Arial, Helvetica, sans-serif" font-size="11" font-weight="700" text-anchor="middle">
    <text x="$(( label_width / 2 ))" y="15" fill="#000">$label</text>
    <text x="$(( label_width + (value_width - 5) / 2 ))" y="15" fill="#fff">$value</text>
  </g>
</svg>
SVG
}

badge version.svg "version" "$version"
badge macos.svg "macOS" "13+"
badge architecture.svg "Apple Silicon + Intel" "universal"
badge languages.svg "language" "RU | EN"
badge swift.svg "Swift" "5.8+"

if stars="$(gh api "repos/$repo" -q .stargazers_count 2>/dev/null)" &&
   downloads="$(gh api "repos/$repo/releases?per_page=100" \
       -q '[.[].assets[] | select((.name | startswith("SHA256SUMS")) or .name == "update.json" | not) | .download_count] | add // 0' 2>/dev/null)"; then
    badge stars.svg "★ stars" "$stars"
    badge downloads.svg "downloads" "$downloads"
    print -r -- "Значки обновлены: версия $version, звёзд $stars, скачиваний $downloads"
else
    print -u2 'GitHub недоступен: значки звёзд и скачиваний не изменены.'
    print -r -- "Значки обновлены: версия $version"
fi

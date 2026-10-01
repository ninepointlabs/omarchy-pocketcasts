#!/bin/bash
# Copy this checkout into the Omarchy plugin directory and enable it.
# Re-run after pulling changes; the shell hot-reloads the copied files.

set -euo pipefail

# Take every tool from the system directories, not from whatever PATH the
# calling shell carries.
PATH=/usr/bin:/bin:/usr/share/omarchy/bin
export PATH

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
id="$(/usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$src/manifest.json")"
dest="$HOME/.config/omarchy/plugins/$id"

mkdir -p "$dest"
# Only ship what the shell needs; git history and tests stay behind.
for entry in manifest.json Model.js Service.qml BarWidget.qml Panel.qml README.md LICENSE bin; do
  [[ -e "$src/$entry" ]] && cp -r "$src/$entry" "$dest/"
done
chmod +x "$dest/bin/pocketcasts-bridge"

if ! command -v mpv >/dev/null 2>&1; then
  echo "Note: mpv is not installed; audio plays through it. Run: omarchy pkg add mpv"
fi
if [[ ! -e /usr/lib/mpv-mpris/mpris.so ]]; then
  echo "Optional: omarchy pkg add mpv-mpris for media keys and playerctl"
fi

if command -v omarchy-shell >/dev/null 2>&1 && omarchy-shell shell ping >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  if ! omarchy plugin list --json 2>/dev/null | grep -q "\"$id\"[^}]*\"enabled\": *true"; then
    omarchy plugin enable "$id" --section "${1:-right}" || true
  fi
fi

echo "Installed $id to $dest"

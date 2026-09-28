#!/usr/bin/env bash
# Rapport de compatibilité des hooks pour une IPA.
# Usage : hooks_report.sh App.ipa rapport.md "Nom=dossier-sources" ["Nom2=dossier2" ...]
# Nécessite GH_TOKEN (pour télécharger ipsw). Ne fait jamais échouer l'appelant sur un souci d'outil.
set -euo pipefail
IPA=$1 REPORT=$2; shift 2
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${RUNNER_TEMP:-/tmp}/hooks-$$"
mkdir -p "$WORK/ipsw" "$WORK/app" "$WORK/dumps"

if ! command -v ipsw >/dev/null; then
  gh release download -R blacktop/ipsw -p 'ipsw_*_linux_x86_64.tar.gz' -D "$WORK/ipsw"
  tar -xzf "$WORK"/ipsw/*.tar.gz -C "$WORK/ipsw"
  IPSW=$(find "$WORK/ipsw" -type f -name ipsw | head -1)
else
  IPSW=$(command -v ipsw)
fi

unzip -q "$IPA" -d "$WORK/app"
APP=$(ls -d "$WORK"/app/Payload/*.app)
plist() { python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))[sys.argv[2]])' "$APP/Info.plist" "$1"; }
EXE=$(plist CFBundleExecutable)
VERSION=$(plist CFBundleShortVersionString)

{ echo "$APP/$EXE"
  for fw in "$APP"/Frameworks/*.framework; do n=$(basename "$fw" .framework); [ -f "$fw/$n" ] && echo "$fw/$n" || true; done
} | while read -r bin; do
  "$IPSW" class-dump "$bin" > "$WORK/dumps/$(basename "$bin").txt" 2>/dev/null || echo "(ignoré : $(basename "$bin"))"
done

args=()
for d in "$WORK"/dumps/*.txt; do args+=(--dump "$d"); done
for s in "$@"; do args+=(--source "$s"); done
python3 "$HERE/check_hooks.py" "${args[@]}" --version "$VERSION" --report "$REPORT"
rm -rf "$WORK"

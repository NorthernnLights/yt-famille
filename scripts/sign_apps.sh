#!/usr/bin/env bash
# Signe chaque app de signing/apps.json (profil Ad Hoc) et la publie sur le portail (R2).
# Usage : sign_apps.sh DOSSIER_SIGNATURE
#   DOSSIER_SIGNATURE contient dist.p12, dist.pass, <id>.mobileprovision et profiles.json (produits par asc.py sync).
# Nécessite : GH_TOKEN, GITHUB_REPOSITORY, CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID, zsign dans le PATH.
set -euo pipefail
SIGN=$1
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${RUNNER_TEMP:-/tmp}/sign-work"
BUCKET=famille-apps
W="npx --yes wrangler@4"
rm -rf "$WORK" && mkdir -p "$WORK"
PASS=$(cat "$SIGN/dist.pass")

releases=$(gh release list --limit 100 --json tagName,publishedAt,isDraft)
catalog="[]"

while IFS=$'\t' read -r id name bundle regex; do
  prov="$SIGN/$id.mobileprovision"
  [ -f "$prov" ] || { echo "::warning::$name : pas de profil, ignoré."; continue; }
  tag=$(jq -r --arg re "$regex" '[.[] | select((.isDraft | not) and (.tagName | test($re)))] | sort_by(.publishedAt) | last | .tagName // empty' <<<"$releases")
  [ -n "$tag" ] || { echo "$name : aucune release trouvée ($regex), ignoré."; continue; }
  echo "==> $name ($tag)"
  rm -rf "$WORK/$id" && mkdir -p "$WORK/$id"
  gh release download "$tag" -p '*.ipa' -D "$WORK/$id"
  src=$(ls "$WORK/$id"/*.ipa | head -1)
  # Les extensions (PlugIns, Watch) demanderaient chacune leur propre profil : on les retire.
  zip -q -d "$src" 'Payload/*.app/PlugIns/*' 'Payload/*.app/Watch/*' 'Payload/*.app/Extensions/*' >/dev/null 2>&1 || true
  out="$WORK/$id/signed.ipa"
  zsign -k "$SIGN/dist.p12" -p "$PASS" -m "$prov" -b "$bundle" -o "$out" "$src"
  version=$(python3 - "$out" <<'PY'
import plistlib, re, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
n = next(n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n))
p = plistlib.loads(z.read(n))
print(p.get("CFBundleShortVersionString") or p.get("CFBundleVersion") or "1.0")
PY
)
  size=$(stat -c %s "$out")
  $W r2 object put "$BUCKET/ipa/$id.ipa" --file "$out" --content-type application/octet-stream --remote
  expires=$(jq -r --arg id "$id" '.apps[$id].expires // ""' "$SIGN/profiles.json")
  catalog=$(jq --arg id "$id" --arg name "$name" --arg bundle "$bundle" --arg version "$version" \
    --arg tag "$tag" --arg expires "$expires" --argjson size "$size" \
    '. + [{id: $id, name: $name, bundle: $bundle, version: $version, tag: $tag, expires: $expires, size: $size}]' <<<"$catalog")
done < <(jq -r '.apps[] | [.id, .name, .bundle, .release] | @tsv' "$HERE/signing/apps.json")

jq -n --argjson apps "$catalog" --arg updated "$(date -u +%FT%TZ)" '{updated: $updated, apps: $apps}' > "$WORK/apps.json"
$W r2 object put "$BUCKET/apps.json" --file "$WORK/apps.json" --content-type application/json --remote
cat "$WORK/apps.json"

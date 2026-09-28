#!/usr/bin/env bash
# Trouve l'IPA source dans les releases (brouillons compris) nommées OU taguées « ios-source ».
#   ios_source.sh info           -> "id|nom|taille|date" de l'IPA la plus récente
#   ios_source.sh download FICH  -> télécharge cette IPA dans FICH
# Nécessite GH_TOKEN et GITHUB_REPOSITORY.
set -euo pipefail

asset=$(gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" --jq '
  [ .[] | select((.tag_name | ascii_downcase) == "ios-source" or (.name // "" | ascii_downcase) == "ios-source")
        | .assets[] | select(.name | ascii_downcase | endswith(".ipa")) ]
  | sort_by(.updated_at) | last
  | if . == null then "" else "\(.id)|\(.name)|\(.size)|\(.updated_at)" end')

if [ -z "$asset" ]; then
  echo "::error::Aucune IPA trouvée. Créez une release (brouillon accepté) nommée ou taguée « ios-source » et joignez-y l'IPA déchiffrée (.ipa), ou passez une URL dans « ipa_url »." >&2
  exit 1
fi

case "${1:-info}" in
  info) echo "$asset" ;;
  download)
    id=${asset%%|*}
    echo "Téléchargement de $(cut -d'|' -f2 <<<"$asset") ($(( $(cut -d'|' -f3 <<<"$asset") / 1048576 )) Mo)" >&2
    curl -fsSL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/octet-stream" \
      "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/assets/$id" -o "$2" ;;
  *) echo "usage: $0 info|download FICHIER" >&2; exit 2 ;;
esac

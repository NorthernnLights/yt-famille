#!/usr/bin/env bash
# Compile YouThibz et ses briques open source en paquets .deb (Linux ou macOS).
# Prérequis : $THEOS installé (toolchain + SDK iOS) et ldid dans le PATH.
# Sortie : tweak-ios/build/debs/*.deb
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/build"
VENDOR="$BUILD/vendor"
DEBS="$BUILD/debs"
: "${THEOS:?THEOS doit pointer vers une installation de Theos}"

MAKE_ARGS=(package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless ARCHS=arm64 "TARGET=iphone:clang:latest:15.0")

rm -rf "$DEBS" && mkdir -p "$VENDOR" "$DEBS"

# 1. Récupérer chaque brique au commit indiqué dans vendor.lock
while read -r name repo sha; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  dir="$VENDOR/$name"
  if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$sha" ]; then
    echo "==> $name ($repo @ ${sha:0:7})"
    rm -rf "$dir" && mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" remote add origin "https://github.com/$repo"
    git -C "$dir" fetch -q --depth 1 origin "$sha"
    git -C "$dir" checkout -q FETCH_HEAD
    git -C "$dir" submodule update -q --init --recursive --depth 1
  fi
done < "$HERE/vendor.lock"

# 2. En-têtes partagés : les tweaks font #import <YouTubeHeader/...> et <PSHeader/...>
for h in YouTubeHeader PSHeader; do
  rm -rf "$THEOS/include/$h"
  ln -s "$VENDOR/$h" "$THEOS/include/$h"
done

build() { # build <dossier> [arguments make supplémentaires]
  local dir=$1; shift
  echo "==> Compilation de $(basename "$dir")"
  rm -rf "$dir/packages" "$dir/.theos"
  make -C "$dir" "${MAKE_ARGS[@]}" "$@"
  cp "$dir"/packages/*.deb "$DEBS/"
}

# 3. Briques open source (YTVideoOverlay sert de socle aux boutons de YouPiP et YouQuality)
build "$VENDOR/YTVideoOverlay"
build "$VENDOR/YouTube-X"
build "$VENDOR/YouPiP"
build "$VENDOR/YouQuality"
build "$VENDOR/Return-YouTube-Dislikes"
# iSponsorBlock déclare libcolorpicker sans l'utiliser : on retire ce lien (indisponible sous Linux).
build "$VENDOR/iSponsorBlock" iSponsorBlock_LIBRARIES=

# 4. Notre propre code
build "$HERE"

echo "==> Paquets produits :"
ls -1 "$DEBS"

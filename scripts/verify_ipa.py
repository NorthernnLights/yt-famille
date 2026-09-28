#!/usr/bin/env python3
"""Vérifie qu'une IPA YouTube est déchiffrée et non modifiée.

Usage : verify_ipa.py YouTube.ipa
Code de sortie : 0 = OK, 1 = IPA inutilisable (chiffrée ou déjà modifiée), 2 = erreur.
"""
import plistlib
import re
import struct
import sys
import zipfile

LC_REQ_DYLD = 0x80000000
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_REEXPORT_DYLIB = 0x1F | LC_REQ_DYLD
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x23 | LC_REQ_DYLD
LC_ENCRYPTION_INFO = 0x21
LC_ENCRYPTION_INFO_64 = 0x2C
DYLIB_CMDS = {LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB}

# Noms laissés par les tweaks et injecteurs les plus courants.
TWEAK_MARKERS = re.compile(
    r"substrate|substitute|ellekit|libhooker|orion\.framework|liborion|uyou|ytlite|youtubeplus|ytplus|cercube|"
    r"youpip|ytuhd|isponsorblock|ytabconfig|youquality|youspeed|donteatmycontent|libflex|flexing|"
    r"returnyoutubedislike|youtubedislikesreturn|ytkace|youmod|ytnoads|alderis|libcolorpicker",
    re.IGNORECASE,
)


def parse_macho(data):
    """Renvoie (cryptids, dylibs) pour chaque tranche d'un Mach-O (fat ou non)."""
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):  # fat
        is64 = magic == 0xCAFEBABF
        n = struct.unpack_from(">I", data, 4)[0]
        slices = []
        for i in range(n):
            if is64:
                _, _, off, _, _, _ = struct.unpack_from(">iiQQII", data, 8 + i * 32)
            else:
                _, _, off, _, _ = struct.unpack_from(">iiIII", data, 8 + i * 20)
            slices.append(off)
    else:
        slices = [0]

    cryptids, dylibs = [], []
    for base in slices:
        m = struct.unpack_from("<I", data, base)[0]
        if m == 0xFEEDFACF:
            hdr = 32
        elif m == 0xFEEDFACE:
            hdr = 28
        else:
            raise ValueError(f"format Mach-O inconnu (magic {m:#x})")
        ncmds = struct.unpack_from("<I", data, base + 16)[0]
        off = base + hdr
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", data, off)
            if cmd in (LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64):
                cryptids.append(struct.unpack_from("<I", data, off + 16)[0])
            elif cmd in DYLIB_CMDS:
                name_off = struct.unpack_from("<I", data, off + 8)[0]
                raw = data[off + name_off: off + size]
                dylibs.append(raw.split(b"\0", 1)[0].decode(errors="replace"))
            off += size
    return cryptids, dylibs


def main(path):
    problems, warnings = [], []
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        apps = sorted({m.group(1) for n in names if (m := re.match(r"(Payload/[^/]+\.app)/", n))})
        if not apps:
            print("::error::Pas de dossier Payload/*.app : ce n'est pas une IPA valide.")
            return 2
        app = apps[0]
        info = plistlib.loads(z.read(f"{app}/Info.plist"))
        exe = info.get("CFBundleExecutable", "YouTube")
        bundle_id = info.get("CFBundleIdentifier", "?")
        version = info.get("CFBundleShortVersionString") or info.get("CFBundleVersion", "?")
        print(f"App : {app}  |  bundle : {bundle_id}  |  version : {version}")

        if bundle_id != "com.google.ios.youtube":
            warnings.append(f"Bundle ID modifié ({bundle_id}) : l'IPA a probablement déjà été retouchée.")
        if info.get("CFBundleDisplayName", "YouTube") != "YouTube":
            warnings.append(f"Nom affiché modifié : {info.get('CFBundleDisplayName')}")

        # 1. Binaire principal : chiffrement et bibliothèques chargées.
        cryptids, dylibs = parse_macho(z.read(f"{app}/{exe}"))
        if any(cryptids):
            problems.append("Le binaire est encore CHIFFRÉ (cryptid=1) : il faut une IPA déchiffrée.")
        tweak_like = [d for d in dylibs if TWEAK_MARKERS.search(d)]
        if tweak_like:
            problems.append("Tweaks chargés par le binaire :\n    " + "\n    ".join(sorted(set(tweak_like))))
        others = [d for d in dylibs if d not in tweak_like
                  and not d.startswith(("/usr/lib/", "/System/")) and d.endswith(".dylib")]
        if others:
            warnings.append("Bibliothèques non système chargées (à vérifier) : " + ", ".join(sorted(set(others))))

        # 2. Fichiers ajoutés dans le bundle.
        suspicious = sorted({n for n in names
                             if n.startswith(f"{app}/") and TWEAK_MARKERS.search(n[len(app):])
                             and re.search(r"\.(dylib|framework|bundle)(/|$)", n)})
        roots = sorted({re.match(r"(.*?\.(?:dylib|framework|bundle))", s).group(1) for s in suspicious})
        if roots:
            problems.append("Fichiers de tweaks présents dans l'app :\n    " + "\n    ".join(roots))

    for w in warnings:
        print(f"::warning::{w}")
    if problems:
        for p in problems:
            print(f"::error::{p}")
        print("\n=> IPA refusée. Il faut l'IPA officielle déchiffrée, sans aucune modification.")
        return 1
    print("=> OK : IPA déchiffrée et sans modification détectée.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    try:
        sys.exit(main(sys.argv[1]))
    except (zipfile.BadZipFile, KeyError, ValueError, struct.error) as e:
        print(f"::error::Lecture de l'IPA impossible : {e}")
        sys.exit(2)

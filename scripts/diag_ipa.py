#!/usr/bin/env python3
"""Diagnostic d'une IPA : structure zip, dossier Payload, Info.plist, liens symboliques, noms suspects."""
import collections, hashlib, plistlib, re, stat, sys, zipfile

def diag(path):
    print(f"\n===== {path}")
    data = open(path, "rb").read()
    print(f"taille : {len(data)/1048576:.1f} Mo  sha256 : {hashlib.sha256(data).hexdigest()[:16]}  début : {data[:4]!r}")
    if data[:2] != b"PK":
        print("!! PAS UN ZIP (probablement une page HTML ou un fichier tronqué)")
        return
    z = zipfile.ZipFile(path)
    bad = z.testzip()
    print("intégrité zip :", "OK" if bad is None else f"!! entrée corrompue : {bad}")
    infos = z.infolist()
    names = [i.filename for i in infos]
    print(f"entrées : {len(infos)}  commentaire zip : {z.comment[:40]!r}")
    print("10 premières :", names[:10])
    tops = collections.Counter(n.split("/")[0] for n in names)
    print("racine :", dict(tops))
    apps = sorted({m.group(1) for n in names if (m := re.match(r"(Payload/[^/]+\.app)/", n))})
    print("apps :", apps)
    methods = collections.Counter(i.compress_type for i in infos)
    print("méthodes de compression :", dict(methods), "(0=stored, 8=deflate)")
    links = [i.filename for i in infos if stat.S_ISLNK(i.external_attr >> 16)]
    print(f"liens symboliques : {len(links)}", links[:5])
    dirs_without_slash = [i.filename for i in infos if stat.S_ISDIR(i.external_attr >> 16) and not i.filename.endswith("/")]
    print("dossiers sans / final :", dirs_without_slash[:5])
    weird = [n for n in names if n.startswith("/") or "\\" in n or ".." in n.split("/") or n.startswith("__MACOSX")]
    print("noms suspects :", weird[:5])
    dup = [n for n, c in collections.Counter(names).items() if c > 1]
    print("doublons :", dup[:5])
    zip64 = [i.filename for i in infos if i.file_size >= 0xFFFFFFFF or i.compress_size >= 0xFFFFFFFF]
    print("entrées zip64 :", len(zip64), "| flags:", dict(collections.Counter(i.flag_bits for i in infos)),
          "| create_system:", dict(collections.Counter(i.create_system for i in infos)))
    if apps:
        app = apps[0]
        try:
            info = plistlib.loads(z.read(f"{app}/Info.plist"))
            exe = info.get("CFBundleExecutable")
            print(f"Info.plist : {info.get('CFBundleIdentifier')} {info.get('CFBundleShortVersionString')} exe={exe} "
                  f"MinimumOSVersion={info.get('MinimumOSVersion')} nom={info.get('CFBundleDisplayName')}")
            print("exécutable présent :", f"{app}/{exe}" in names)
        except Exception as e:
            print("!! Info.plist illisible :", e)
        print("Frameworks :", sorted({n.split('/')[3] for n in names if n.startswith(f'{app}/Frameworks/') and n.count('/') >= 3})[:40])

for p in sys.argv[1:]:
    diag(p)

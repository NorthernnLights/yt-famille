#!/usr/bin/env python3
"""Retire d'un binaire Mach-O les commandes de chargement (LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB)
de certaines bibliothèques. Sert à ce que les briques injectées ne se chargent plus d'office :
c'est YouThibz qui les charge au démarrage, selon ses réglages.

Usage : strip_load_commands.py BINAIRE CHEMIN [CHEMIN ...]
  CHEMIN : chemin exact tel qu'enregistré dans le binaire, ex. @rpath/YouPiP.dylib

Seules les bibliothèques injectées (ajoutées en fin de liste, et dont le binaire n'importe
aucun symbole) peuvent être retirées sans risque : les numéros des bibliothèques d'origine
ne bougent pas. Le script refuse donc de retirer une bibliothèque suivie d'une bibliothèque
qui n'est pas elle-même retirée ou injectée par nous (@rpath/…).
"""
import struct
import sys

LC_REQ_DYLD = 0x80000000
DYLIB_CMDS = {0xC, 0x18 | LC_REQ_DYLD, 0x1F | LC_REQ_DYLD, 0x20, 0x23 | LC_REQ_DYLD}


def slices(data):
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        is64 = magic == 0xCAFEBABF
        n = struct.unpack_from(">I", data, 4)[0]
        for i in range(n):
            if is64:
                yield struct.unpack_from(">iiQQII", data, 8 + i * 32)[2]
            else:
                yield struct.unpack_from(">iiIII", data, 8 + i * 20)[2]
    else:
        yield 0


def strip_slice(data, base, targets):
    magic = struct.unpack_from("<I", data, base)[0]
    if magic == 0xFEEDFACF:
        hdr = 32
    elif magic == 0xFEEDFACE:
        hdr = 28
    else:
        raise ValueError(f"format Mach-O inconnu (magic {magic:#x})")
    ncmds, sizeofcmds = struct.unpack_from("<II", data, base + 16)
    off = base + hdr
    cmds = []  # (cmd, octets, nom de dylib ou None)
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        raw = bytes(data[off:off + size])
        name = None
        if cmd in DYLIB_CMDS:
            name_off = struct.unpack_from("<I", raw, 8)[0]
            name = raw[name_off:].split(b"\0", 1)[0].decode(errors="replace")
        cmds.append((cmd, raw, name))
        off += size

    dylibs = [name for _, _, name in cmds if name is not None]
    removed = [n for n in dylibs if n in targets]
    # Sécurité : après la première bibliothèque retirée, il ne doit rester que des ajouts @rpath/.
    if removed:
        first = dylibs.index(removed[0])
        for n in dylibs[first:]:
            if n not in targets and not n.startswith("@rpath/"):
                raise ValueError(f"{n} suit une bibliothèque à retirer : ordre inattendu, abandon.")

    kept = [raw for _, raw, name in cmds if name is None or name not in targets]
    blob = b"".join(kept)
    data[base + hdr: base + hdr + sizeofcmds] = blob + b"\0" * (sizeofcmds - len(blob))
    struct.pack_into("<II", data, base + 16, len(kept), len(blob))
    return removed


def main(path, *targets):
    targets = set(targets)
    data = bytearray(open(path, "rb").read())
    removed = set()
    for base in slices(data):
        removed |= set(strip_slice(data, base, targets))
    open(path, "wb").write(data)
    for n in sorted(removed):
        print(f"retiré : {n}")
    missing = targets - removed
    for n in sorted(missing):
        print(f"::warning::{n} n'était pas chargé par {path}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(*sys.argv[1:]))

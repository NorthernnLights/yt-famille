#!/usr/bin/env python3
"""Vérifie que les classes et méthodes modifiées par les tweaks existent dans une version de YouTube.

Usage :
  check_hooks.py --dump DUMP.txt [--dump ...] --source NOM=DOSSIER [--source ...] [--report RAPPORT.md]

- DUMP.txt : sortie de `ipsw class-dump <binaire Mach-O>` (format non verbeux), un fichier par binaire.
- NOM=DOSSIER : un composant (notre code ou une brique) et le dossier de ses sources Logos (.x / .xm).

Le script ne fait jamais échouer le build : il produit un rapport. Code de sortie 0.
"""
import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

# ---------------------------------------------------------------- dump ObjC de YouTube

INTERFACE = re.compile(r"^@interface\s+([\w.$]+)\s*(?:\((\w*)\))?\s*(?::\s*([\w.$<>]+))?")
METHOD = re.compile(r"^([-+])\[([\w.$]+)(?:\(\w*\))?\s+([^\]]+)\];")
PROPERTY = re.compile(r"^@property\s*\(([^)]*)\)\s*(\w+)\s*;")


class Runtime:
    def __init__(self):
        self.supers = {}                 # classe -> superclasse
        self.methods = defaultdict(set)  # classe -> {"-sel", "+sel"}

    def load(self, path):
        current = None
        for line in Path(path).read_text(errors="replace").splitlines():
            line = line.strip()
            m = INTERFACE.match(line)
            if m:
                current = m.group(1)
                if m.group(3) and m.group(2) is None:
                    self.supers[current] = m.group(3)
                self.methods.setdefault(current, set())
                continue
            m = METHOD.match(line)
            if m:
                self.methods[m.group(2)].add(m.group(1) + m.group(3).strip())
                continue
            m = PROPERTY.match(line)
            if m and current:
                attrs, name = m.group(1), m.group(2)
                getter = next((a[1:] for a in attrs.split(",") if a.startswith("G")), name)
                setter = next((a[1:] for a in attrs.split(",") if a.startswith("S")),
                              "set" + name[:1].upper() + name[1:] + ":")
                self.methods[current].add("-" + getter)
                if ",R" not in "," + attrs:  # pas en lecture seule
                    self.methods[current].add("-" + setter)
                continue
            if line == "@end":
                current = None

    def has_class(self, cls):
        return cls in self.methods

    def find(self, cls, kind_sel):
        """True si trouvé, False si absent, None si la chaîne d'héritage sort de YouTube (UIKit…)."""
        seen = set()
        while cls and cls not in seen:
            seen.add(cls)
            if cls not in self.methods:
                return None  # classe système : on ne peut pas vérifier
            if kind_sel in self.methods[cls]:
                return True
            cls = self.supers.get(cls)
        return False


# ---------------------------------------------------------------- hooks Logos

HOOK = re.compile(r"^\s*%hook\s+([\w.$]+)")
END = re.compile(r"^\s*%end\b")
NEW = re.compile(r"^\s*%new\b")
METHOD_START = re.compile(r"^\s*([-+])\s*\(")
CLASS_REF = re.compile(r'%c\(\s*([\w.$]+)\s*\)|NSClassFromString\(\s*@"([\w.$]+)"\s*\)|objc_getClass\(\s*"([\w.$]+)"\s*\)')


def selector_of(signature):
    """« - (void)foo:(int)a bar:(id)b » -> « foo:bar: »."""
    sig = re.sub(r"^\s*[-+]\s*\([^)]*\)\s*", "", signature)
    parts = re.findall(r"(\w+)\s*:\s*(?:\([^)]*\))?\s*\w+", sig)
    if parts:
        return "".join(p + ":" for p in parts)
    m = re.match(r"(\w+)", sig)
    return m.group(1) if m else None


def parse_hooks(folder):
    """Renvoie [(fichier, ligne, classe, "-sel" ou None pour la classe seule)] et les références de classes."""
    hooks, refs = [], []
    for f in sorted(Path(folder).rglob("*")):
        if f.suffix not in (".x", ".xm", ".xi") or "/.theos/" in str(f) or "Simulator" in str(f):
            continue
        lines = f.read_text(errors="replace").splitlines()
        cls, skip_next, i = None, False, 0
        while i < len(lines):
            line = lines[i]
            for m in CLASS_REF.finditer(line):
                refs.append((f, i + 1, next(g for g in m.groups() if g)))
            if (m := HOOK.match(line)):
                cls = m.group(1)
                hooks.append((f, i + 1, cls, None))
            elif END.match(line):
                cls = None
            elif NEW.match(line):
                skip_next = True
            elif cls and (m := METHOD_START.match(line)):
                sig, j = line, i
                while "{" not in sig and ";" not in sig and j + 1 < len(lines):
                    j += 1
                    sig += " " + lines[j].strip()
                sig = sig.split("{")[0]
                sel = selector_of(sig)
                if sel and not skip_next:
                    hooks.append((f, i + 1, cls, m.group(1) + sel))
                skip_next = False
                i = j
            i += 1
    return hooks, refs


# ---------------------------------------------------------------- rapport

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", action="append", required=True)
    ap.add_argument("--source", action="append", required=True, help="NOM=DOSSIER")
    ap.add_argument("--report", default=None)
    ap.add_argument("--version", default="?")
    args = ap.parse_args()

    rt = Runtime()
    for d in args.dump:
        rt.load(d)
    if len(rt.methods) < 100:
        print(f"::warning::Seulement {len(rt.methods)} classes lues dans le dump : le rapport n'est pas fiable.")

    out = [f"## Compatibilité des hooks avec YouTube {args.version}", "",
           f"{len(rt.methods)} classes Objective-C trouvées dans l'app.", "",
           "| Composant | Hooks vérifiés | OK | Absents | Non vérifiables* |", "|---|---:|---:|---:|---:|"]
    details = []
    total_missing = 0
    for spec in args.source:
        name, folder = spec.split("=", 1)
        hooks, refs = parse_hooks(folder)
        ok = missing = unknown = 0
        lines = []
        for f, ln, cls, sel in hooks:
            where = f"`{Path(f).name}:{ln}`"
            if not rt.has_class(cls):
                if sel is None:
                    missing += 1
                    lines.append(f"- classe **{cls}** absente ({where})")
                continue
            if sel is None:
                continue
            found = rt.find(cls, sel)
            if found:
                ok += 1
            elif found is None:
                unknown += 1
            else:
                missing += 1
                lines.append(f"- méthode **{sel[0]}[{cls} {sel[1:]}]** absente ({where})")
        missing_refs = sorted({c for _, _, c in refs if not rt.has_class(c) and not c.startswith(("UI", "NS", "AV", "CA", "MP"))})
        total_missing += missing
        out.append(f"| {name} | {ok + missing + unknown} | {ok} | {missing} | {unknown} |")
        if lines or missing_refs:
            details.append(f"### {name}")
            details += lines
            if missing_refs:
                details.append("- classes référencées mais introuvables (souvent des détections optionnelles) : "
                               + ", ".join(f"`{c}`" for c in missing_refs))
            details.append("")

    out += ["", "\\* méthode héritée d'une classe système (UIKit…), non vérifiable dans le binaire de YouTube.",
            "", "Certaines briques visent volontairement plusieurs variantes d'une même méthode selon la version de YouTube : "
            "une absence isolée n'est pas forcément une panne. Ce qui compte, c'est ce qui **change** d'une version à l'autre.", ""]
    out.append("✅ Aucun hook cassé détecté." if total_missing == 0
               else f"⚠️ **{total_missing} hook(s) ne trouvent plus leur cible** : les fonctions concernées ne marcheront pas.")
    out += [""] + details
    text = "\n".join(out)
    print(text)
    if args.report:
        Path(args.report).write_text(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

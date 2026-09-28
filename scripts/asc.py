#!/usr/bin/env python3
"""Automatisation du compte développeur Apple (API App Store Connect) pour la distribution Ad Hoc.

  asc.py sync  --apps signing/apps.json --out DIR [--p12 dist.p12 --p12-pass MOTDEPASSE]
      1. enregistre sur le compte Apple les iPhone inscrits sur le portail familial ;
      2. retrouve (ou crée) le certificat « Apple Distribution » ;
      3. crée les identifiants d'app manquants ;
      4. régénère un profil Ad Hoc par app, avec tous les appareils actifs.
      Écrit dans DIR : <id>.mobileprovision, profiles.json, et dist.p12 + dist.pass si un certificat a été créé.

  asc.py mark-ready --udids UDID[,UDID...]
      Indique au portail que ces iPhone peuvent installer les apps.

Variables d'environnement : ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY (contenu du fichier .p8),
PORTAL_URL, PORTAL_ADMIN_TOKEN.
"""
import argparse
import base64
import json
import os
import re
import secrets
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.appstoreconnect.apple.com/v1"
PROFILE_PREFIX = "famille "


# ------------------------------------------------------------------ HTTP

def http(method, url, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("accept", "application/json")
    if data is not None:
        req.add_header("content-type", "application/json")
    if token:
        req.add_header("authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:800]
        raise SystemExit(f"::error::{method} {url} -> HTTP {e.code} : {detail}")


class ASC:
    def __init__(self, key_id, issuer, private_key):
        import jwt  # PyJWT
        self._make = lambda: jwt.encode(
            {"iss": issuer, "iat": int(time.time()), "exp": int(time.time()) + 900, "aud": "appstoreconnect-v1"},
            private_key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"})

    def req(self, method, path, body=None):
        return http(method, path if path.startswith("http") else API + path, self._make(), body)

    def all(self, path):
        out, url = [], API + path
        while url:
            page = self.req("GET", url)
            out += page.get("data", [])
            url = page.get("links", {}).get("next")
        return out


# ------------------------------------------------------------------ portail

def portal(method, path, body=None):
    base, token = os.environ.get("PORTAL_URL", "").rstrip("/"), os.environ.get("PORTAL_ADMIN_TOKEN", "")
    if not base or not token:
        print("::warning::PORTAL_URL / PORTAL_ADMIN_TOKEN absents : appareils du portail ignorés.")
        return None
    return http(method, base + path, token, body)


# ------------------------------------------------------------------ étapes

def sync_devices(asc):
    known = {d["attributes"]["udid"].upper(): d for d in asc.all("/devices?limit=200&filter[platform]=IOS")}
    for dev in portal("GET", "/api/devices") or []:
        udid = dev["udid"].upper()
        if udid not in known:
            name = re.sub(r"[^\w .,'-]", "", f"{dev.get('name', 'iPhone')} {dev.get('product', '')}".strip())[:50]
            print(f"Enregistrement de l'appareil {name} ({udid})")
            created = asc.req("POST", "/devices", {"data": {"type": "devices", "attributes": {
                "name": name or "iPhone", "udid": dev["udid"], "platform": "IOS"}}})
            known[udid] = created["data"]
        if dev.get("status") == "pending":
            portal("PATCH", f"/api/devices/{dev['udid']}", {"status": "registered"})
    enabled = [d for d in known.values()
               if d["attributes"].get("status", "ENABLED") == "ENABLED"
               and d["attributes"].get("deviceClass", "IPHONE") in ("IPHONE", "IPAD", "IPOD")]
    print(f"{len(enabled)} appareil(s) actif(s) sur le compte Apple.")
    return enabled


def load_p12(path, password):
    from cryptography.hazmat.primitives.serialization import pkcs12
    key, cert, _ = pkcs12.load_key_and_certificates(Path(path).read_bytes(), password.encode())
    return key, cert


def ensure_certificate(asc, out, p12, p12_pass):
    certs = asc.all("/certificates?limit=200&filter[certificateType]=DISTRIBUTION")
    if p12 and Path(p12).exists():
        _, cert = load_p12(p12, p12_pass)
        for c in certs:
            if int(c["attributes"]["serialNumber"], 16) == cert.serial_number:
                print(f"Certificat existant : {c['attributes'].get('displayName', c['id'])} (expire {c['attributes'].get('expirationDate', '?')[:10]})")
                return c["id"]
        print("::warning::Le certificat enregistré n'existe plus chez Apple (révoqué ou expiré) : création d'un nouveau.")
    return create_certificate(asc, out)


def create_certificate(asc, out):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives.serialization import pkcs12
    from cryptography.x509.oid import NameOID

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (x509.CertificateSigningRequestBuilder()
           .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "famille-apps"),
                                    x509.NameAttribute(NameOID.COUNTRY_NAME, "FR")]))
           .sign(key, hashes.SHA256()))
    pem = csr.public_bytes(serialization.Encoding.PEM).decode()
    created = asc.req("POST", "/certificates", {"data": {"type": "certificates", "attributes": {
        "csrContent": pem, "certificateType": "DISTRIBUTION"}}})
    cert = x509.load_der_x509_certificate(base64.b64decode(created["data"]["attributes"]["certificateContent"]))
    password = secrets.token_urlsafe(24)
    p12 = pkcs12.serialize_key_and_certificates(
        b"famille-apps", key, cert, None, serialization.BestAvailableEncryption(password.encode()))
    (out / "dist.p12").write_bytes(p12)
    (out / "dist.pass").write_text(password)
    print(f"Nouveau certificat Apple Distribution créé (id {created['data']['id']}).")
    return created["data"]["id"]


def ensure_bundle_id(asc, app):
    found = asc.req("GET", f"/bundleIds?filter[identifier]={app['bundle']}")["data"]
    found = [b for b in found if b["attributes"]["identifier"] == app["bundle"]]
    if found:
        return found[0]["id"]
    name = re.sub(r"[^A-Za-z0-9 ]", "", app["name"]) or app["id"]
    print(f"Création de l'identifiant d'app {app['bundle']}")
    return asc.req("POST", "/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": app["bundle"], "name": name, "platform": "IOS"}}})["data"]["id"]


def regenerate_profile(asc, app, bundle_id, cert_id, devices, out):
    name = PROFILE_PREFIX + app["id"]
    for old in asc.req("GET", f"/profiles?filter[name]={urllib.request.quote(name)}")["data"]:
        asc.req("DELETE", f"/profiles/{old['id']}")
    created = asc.req("POST", "/profiles", {"data": {
        "type": "profiles",
        "attributes": {"name": name, "profileType": "IOS_APP_ADHOC"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
            "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
            "devices": {"data": [{"type": "devices", "id": d["id"]} for d in devices]},
        }}})["data"]
    (out / f"{app['id']}.mobileprovision").write_bytes(base64.b64decode(created["attributes"]["profileContent"]))
    print(f"Profil Ad Hoc « {name} » : {len(devices)} appareil(s), expire le {created['attributes'].get('expirationDate', '?')[:10]}")
    return created["attributes"].get("expirationDate")


def cmd_sync(args):
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    key = os.environ["ASC_PRIVATE_KEY"]
    if "BEGIN" not in key:  # clé passée en base64
        key = base64.b64decode(key).decode()
    asc = ASC(os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], key)

    devices = sync_devices(asc)
    if not devices:
        print("::warning::Aucun appareil enregistré : inscrivez d'abord un iPhone sur le portail.")
    cert_id = ensure_certificate(asc, out, args.p12, args.p12_pass or "")
    apps = json.loads(Path(args.apps).read_text())["apps"]
    summary = {"udids": [d["attributes"]["udid"] for d in devices], "apps": {}}
    for app in apps:
        bundle_id = ensure_bundle_id(asc, app)
        if devices:
            summary["apps"][app["id"]] = {"expires": regenerate_profile(asc, app, bundle_id, cert_id, devices, out)}
    (out / "profiles.json").write_text(json.dumps(summary, indent=2))


def cmd_mark_ready(args):
    for udid in filter(None, args.udids.split(",")):
        portal("PATCH", f"/api/devices/{udid}", {"status": "ready"})


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sync")
    s.add_argument("--apps", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--p12")
    s.add_argument("--p12-pass")
    s.set_defaults(func=cmd_sync)
    r = sub.add_parser("mark-ready")
    r.add_argument("--udids", required=True)
    r.set_defaults(func=cmd_mark_ready)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    sys.exit(main())

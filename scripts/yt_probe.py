#!/usr/bin/env python3
"""Teste quels clients InnerTube renvoient des liens de téléchargement directs (sans jeton PO).
Usage : yt_probe.py [ID_VIDEO ...]   — sert à ajuster le téléchargement de YouThibz.
Définitions des clients reprises de yt-dlp (yt_dlp/extractor/youtube/_base.py)."""
import http.cookiejar
import json
import re
import sys
import urllib.error
import urllib.request

JAR = http.cookiejar.CookieJar()
OPENER = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(JAR))
WEB_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

CLIENTS = {
    "visionos": (101, {"clientName": "VISIONOS", "clientVersion": "1.02", "deviceMake": "Apple",
                       "deviceModel": "RealityDevice17,1", "osName": "visionOS", "osVersion": "26.5.23O471"},
                 "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"),
    "ios": (5, {"clientName": "IOS", "clientVersion": "21.26.4", "deviceMake": "Apple", "deviceModel": "iPhone16,2",
                "osName": "iPhone", "osVersion": "18.3.2.22D82"},
            "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"),
    "tv": (7, {"clientName": "TVHTML5", "clientVersion": "7.20260707.07.00"},
           "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"),
    "android_vr": (28, {"clientName": "ANDROID_VR", "clientVersion": "1.65.10", "deviceMake": "Oculus", "deviceModel": "Quest 3",
                        "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L"},
                   "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"),
}


def post(url, body, headers):
    req = urllib.request.Request(url, json.dumps(body).encode(), headers)
    with OPENER.open(req, timeout=30) as r:
        return json.load(r)


def visitor_data(video_id):
    """Comme yt-dlp : la page de la vidéo fournit VISITOR_DATA (et des cookies de visiteur)."""
    req = urllib.request.Request(f"https://www.youtube.com/watch?v={video_id}&bpctr=9999999999&has_verified=1",
                                 headers={"User-Agent": WEB_UA, "Accept-Language": "fr-FR,fr;q=0.9"})
    with OPENER.open(req, timeout=30) as r:
        html = r.read().decode("utf-8", "replace")
    m = re.search(r'"VISITOR_DATA"\s*:\s*"([^"]+)"', html)
    return m.group(1) if m else None


def status(url, ua):
    sep = "&" if "?" in url else "?"
    req = urllib.request.Request(f"{url}{sep}range=0-65535", headers={"User-Agent": ua})
    try:
        with OPENER.open(req, timeout=30) as r:
            return f"{r.status} ({len(r.read())} o)"
    except urllib.error.HTTPError as e:
        return f"HTTP {e.code}"
    except Exception as e:  # noqa
        return f"erreur {e}"


def fetch_text(url, ua):
    req = urllib.request.Request(url, headers={"User-Agent": ua})
    with OPENER.open(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")


def show_hls(url, ua):
    """Affiche la structure du flux HLS (format des segments : TS ou MP4 fragmenté)."""
    try:
        master = fetch_text(url, ua)
    except Exception as e:  # noqa
        print(f"   HLS maître : erreur {e}")
        return
    lines = master.splitlines()
    print(f"   HLS maître : {len(lines)} lignes")
    for l in lines[:40]:
        print("     " + (l[:160] + "…" if len(l) > 160 else l))
    variants = [l for l in lines if l and not l.startswith("#")]
    if variants:
        try:
            media = fetch_text(variants[-1], ua).splitlines()
            print(f"   HLS variante (dernière) : {len(media)} lignes")
            for l in media[:14]:
                print("     " + (l[:160] + "…" if len(l) > 160 else l))
            seg = next((l for l in media if l and not l.startswith("#")), None)
            if seg:
                req = urllib.request.Request(seg, headers={"User-Agent": ua, "Range": "bytes=0-15"})
                with OPENER.open(req, timeout=30) as r:
                    head = r.read(16)
                print(f"   1er segment : HTTP {r.status}, premiers octets {head.hex()} ({'TS' if head[:1] == b'G' else 'MP4 ?'})")
        except Exception as e:  # noqa
            print(f"   HLS variante : erreur {e}")


def probe(video_id, with_visitor):
    JAR.clear()
    vd = visitor_data(video_id) if with_visitor else None
    print(f"\n######## {video_id} — visitorData : {'oui' if vd else 'non'}")
    for name, (cid, client, ua) in CLIENTS.items():
        extra = {"visitorData": vd} if vd else {}
        body = {"context": {"client": {**client, **extra, "hl": "fr", "gl": "FR"}}, "videoId": video_id,
                "contentCheckOk": True, "racyCheckOk": True,
                "playbackContext": {"contentPlaybackContext": {"html5Preference": "HTML5_PREF_WANTS"}}}
        headers = {"Content-Type": "application/json", "User-Agent": ua, "Origin": "https://www.youtube.com",
                   "X-YouTube-Client-Name": str(cid), "X-YouTube-Client-Version": client["clientVersion"]}
        if vd:
            headers["X-Goog-Visitor-Id"] = vd
        try:
            d = post("https://www.youtube.com/youtubei/v1/player?prettyPrint=false", body, headers)
        except Exception as e:  # noqa
            print(f"== {name}: requête refusée ({e})")
            continue
        ps = d.get("playabilityStatus", {})
        sd = d.get("streamingData", {})
        fmts = sd.get("formats", []) + sd.get("adaptiveFormats", [])
        direct = [f for f in fmts if "url" in f]
        print(f"== {name}: {ps.get('status')} {ps.get('reason') or ''} | formats {len(fmts)}, liens directs {len(direct)}, "
              f"chiffrés {sum('signatureCipher' in f for f in fmts)}, hls {'hlsManifestUrl' in sd}, sabr {'serverAbrStreamingUrl' in sd}")
        vids = sorted((f for f in direct if f.get("mimeType", "").startswith("video/mp4") and "avc1" in f["mimeType"]),
                      key=lambda f: f.get("height", 0))
        auds = sorted((f for f in direct if f.get("mimeType", "").startswith("audio/mp4")), key=lambda f: f.get("bitrate", 0))
        muxed = [f for f in direct if "mp4a" in f.get("mimeType", "") and f.get("mimeType", "").startswith("video/")]
        if sd.get("hlsManifestUrl") and "--hls" in sys.argv:
            show_hls(sd["hlsManifestUrl"], ua)
        for label, f in (("vidéo H.264 max", vids[-1] if vids else None), ("audio AAC max", auds[-1] if auds else None),
                         ("tout-en-un", muxed[-1] if muxed else None)):
            if f:
                print(f"   {label}: itag {f['itag']} {f.get('qualityLabel', '')} {f.get('contentLength', '?')} o -> {status(f['url'], ua)}")


if __name__ == "__main__":
    for vid in [a for a in sys.argv[1:] if not a.startswith("--")] or ["dQw4w9WgXcQ", "jNQXAC9IVRw"]:
        probe(vid, with_visitor=False)
        if "--hls" not in sys.argv:
            probe(vid, with_visitor=True)

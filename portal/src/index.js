// Portail familial (Cloudflare Worker + R2).
//  - Page d'accueil protégée par un code familial (FAMILY_CODE).
//  - Enregistrement d'un iPhone : profil de configuration « Profile Service » qui renvoie l'UDID,
//    enregistré dans R2 puis ajouté automatiquement au compte Apple par le workflow « Signature iOS ».
//  - Installation des apps signées (liens itms-services, IPA servies depuis R2).
//  - API d'administration (ADMIN_TOKEN) utilisée par le workflow de signature.

const COOKIE = "fk";
const WORKFLOW = "ios-sign.yml";

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;
    try {
      if (path.startsWith("/api/")) return await api(request, env, url);

      const code = url.searchParams.get("k") || cookie(request, COOKIE);
      const authed = !!code && safeEqual(code, env.FAMILY_CODE || "");

      if (path === "/enroll/callback" && request.method === "POST") {
        if (!authed) return text("Code familial invalide.", 403);
        return await enrollCallback(request, env, ctx, url, code);
      }
      if (!authed) return loginPage(url, !!url.searchParams.get("k"));

      const setCookie = url.searchParams.get("k") ? cookieHeader(COOKIE, code) : null;
      if (path === "/") return withCookie(await homePage(env, url, code, request), setCookie);
      if (path === "/enroll.mobileconfig") return enrollProfile(url, code);
      if (path === "/udid") return withCookie(await udidPage(env, url, code), setCookie);
      let m = path.match(/^\/manifest\/([a-z0-9-]+)\.plist$/);
      if (m) return await manifest(env, url, code, m[1]);
      m = path.match(/^\/ipa\/([a-z0-9-]+)\.ipa$/);
      if (m) return await ipa(env, m[1]);
      return text("Page introuvable.", 404);
    } catch (e) {
      return text("Erreur : " + (e && e.message ? e.message : e), 500);
    }
  },
};

// ------------------------------------------------------------------ enregistrement d'un iPhone

function enrollProfile(url, code) {
  const name = (url.searchParams.get("n") || "").slice(0, 40);
  const callback = `${url.origin}/enroll/callback?k=${encodeURIComponent(code)}&n=${encodeURIComponent(name)}`;
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <dict>
    <key>URL</key>
    <string>${xml(callback)}</string>
    <key>DeviceAttributes</key>
    <array>
      <string>UDID</string>
      <string>PRODUCT</string>
      <string>VERSION</string>
      <string>DEVICE_NAME</string>
    </array>
  </dict>
  <key>PayloadOrganization</key>
  <string>Famille</string>
  <key>PayloadDisplayName</key>
  <string>Identifiant de l'iPhone (famille)</string>
  <key>PayloadDescription</key>
  <string>Transmet uniquement l'identifiant (UDID) et le modèle de cet iPhone pour autoriser l'installation des apps familiales. Aucun réglage n'est modifié.</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
  <key>PayloadUUID</key>
  <string>${crypto.randomUUID().toUpperCase()}</string>
  <key>PayloadIdentifier</key>
  <string>fr.famille.udid</string>
  <key>PayloadType</key>
  <string>Profile Service</string>
</dict>
</plist>
`;
  return new Response(body, {
    headers: {
      "content-type": "application/x-apple-aspen-config",
      "content-disposition": 'attachment; filename="iphone-famille.mobileconfig"',
    },
  });
}

// L'iPhone envoie un PKCS#7 signé qui contient un plist en clair : on en extrait les attributs.
export function parseDeviceAttributes(bytes) {
  const start = indexOfBytes(bytes, "<?xml");
  const end = indexOfBytes(bytes, "</plist>", start);
  if (start < 0 || end < 0) throw new Error("réponse de l'iPhone illisible");
  const plist = new TextDecoder("utf-8").decode(bytes.slice(start, end + 8));
  const get = (key) => {
    const m = plist.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`));
    return m ? unxml(m[1]) : "";
  };
  return { udid: get("UDID"), product: get("PRODUCT"), version: get("VERSION"), deviceName: get("DEVICE_NAME") };
}

function indexOfBytes(bytes, ascii, from = 0) {
  const needle = Array.from(ascii, (c) => c.charCodeAt(0));
  outer: for (let i = Math.max(from, 0); i <= bytes.length - needle.length; i++) {
    for (let j = 0; j < needle.length; j++) if (bytes[i + j] !== needle[j]) continue outer;
    return i;
  }
  return -1;
}

async function enrollCallback(request, env, ctx, url, code) {
  const attrs = parseDeviceAttributes(new Uint8Array(await request.arrayBuffer()));
  if (!/^[0-9A-Fa-f-]{24,40}$/.test(attrs.udid)) return text("UDID invalide.", 400);
  const name = (url.searchParams.get("n") || attrs.deviceName || "iPhone").slice(0, 40);
  const key = `devices/${attrs.udid}.json`;
  const existing = await readJson(env, key);
  const device = existing || { udid: attrs.udid, status: "pending", created: new Date().toISOString() };
  Object.assign(device, { name, product: attrs.product, version: attrs.version, updated: new Date().toISOString() });
  await env.BUCKET.put(key, JSON.stringify(device, null, 2), { httpMetadata: { contentType: "application/json" } });
  if (device.status === "pending") ctx.waitUntil(dispatchSigning(env).catch(() => {}));
  // iOS attend une redirection 301 : Safari ouvre alors la page qui affiche l'UDID.
  return Response.redirect(`${url.origin}/udid?u=${encodeURIComponent(attrs.udid)}&k=${encodeURIComponent(code)}`, 301);
}

async function dispatchSigning(env) {
  if (!env.GH_DISPATCH_TOKEN || !env.GH_REPO) return;
  await fetch(`https://api.github.com/repos/${env.GH_REPO}/actions/workflows/${WORKFLOW}/dispatches`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.GH_DISPATCH_TOKEN}`,
      accept: "application/vnd.github+json",
      "user-agent": "famille-apps-portal",
      "content-type": "application/json",
    },
    body: JSON.stringify({ ref: "main" }),
  });
}

// ------------------------------------------------------------------ installation des apps

async function manifest(env, url, code, id) {
  const app = (await catalog(env)).apps.find((a) => a.id === id);
  if (!app) return text("App inconnue.", 404);
  const ipaUrl = `${url.origin}/ipa/${id}.ipa?k=${encodeURIComponent(code)}`;
  const body = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>${xml(ipaUrl)}</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>${xml(app.bundle)}</string>
        <key>bundle-version</key>
        <string>${xml(app.version || "1.0")}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>${xml(app.name)}</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
`;
  return new Response(body, { headers: { "content-type": "application/xml" } });
}

async function ipa(env, id) {
  const obj = await env.BUCKET.get(`ipa/${id}.ipa`);
  if (!obj) return text("IPA introuvable.", 404);
  return new Response(obj.body, {
    headers: {
      "content-type": "application/octet-stream",
      "content-length": String(obj.size),
      "cache-control": "no-store",
    },
  });
}

async function catalog(env) {
  return (await readJson(env, "apps.json")) || { apps: [], devices: [] };
}

// ------------------------------------------------------------------ API d'administration

async function api(request, env, url) {
  const auth = request.headers.get("authorization") || "";
  if (!env.ADMIN_TOKEN || !safeEqual(auth, `Bearer ${env.ADMIN_TOKEN}`)) return text("Non autorisé.", 401);
  if (url.pathname === "/api/devices" && request.method === "GET") {
    const devices = [];
    let cursor;
    do {
      const list = await env.BUCKET.list({ prefix: "devices/", cursor });
      for (const o of list.objects) devices.push(await readJson(env, o.key));
      cursor = list.truncated ? list.cursor : undefined;
    } while (cursor);
    return json(devices.filter(Boolean));
  }
  const m = url.pathname.match(/^\/api\/devices\/([0-9A-Fa-f-]{24,40})$/);
  if (m && request.method === "PATCH") {
    const key = `devices/${m[1]}.json`;
    const device = await readJson(env, key);
    if (!device) return text("Appareil inconnu.", 404);
    Object.assign(device, await request.json(), { updated: new Date().toISOString() });
    await env.BUCKET.put(key, JSON.stringify(device, null, 2), { httpMetadata: { contentType: "application/json" } });
    return json(device);
  }
  return text("Route inconnue.", 404);
}

// ------------------------------------------------------------------ pages

const STATUS = {
  pending: ["⏳", "En cours d'ajout au compte Apple (quelques minutes)."],
  registered: ["⏳", "Ajouté au compte Apple, signature des apps en cours (quelques minutes)."],
  ready: ["✅", "Prêt : vous pouvez installer les apps."],
  error: ["⚠️", "Problème lors de l'ajout. Prévenez Thibault."],
};

function statusLine(device) {
  const [icon, label] = STATUS[device.status] || ["❔", device.status];
  return `${icon} ${esc(label)}`;
}

async function homePage(env, url, code, request) {
  const cat = await catalog(env);
  const myUdid = cookie(request, "udid");
  const me = myUdid ? await readJson(env, `devices/${myUdid}.json`) : null;
  const k = encodeURIComponent(code);
  const apps = cat.apps.length
    ? cat.apps.map((a) => {
        const manifestUrl = `${url.origin}/manifest/${a.id}.plist?k=${k}`;
        const link = `itms-services://?action=download-manifest&url=${encodeURIComponent(manifestUrl)}`;
        const meta = [a.version && `version ${a.version}`, a.size && `${Math.round(a.size / 1048576)} Mo`, a.expires && `valable jusqu'au ${a.expires.slice(0, 10)}`]
          .filter(Boolean).join(" · ");
        return `<div class="app"><div><b>${esc(a.name)}</b><small>${esc(meta)}</small></div><a class="btn" href="${esc(link)}">Installer</a></div>`;
      }).join("")
    : `<p>Aucune app disponible pour l'instant.</p>`;
  return page("Apps de la famille", `
    <h1>Apps de la famille</h1>
    ${me ? `<p class="card">Mon iPhone (${esc(me.name)}) : ${statusLine(me)}</p>` : ""}
    <h2>1. Enregistrer mon iPhone <small>(une seule fois)</small></h2>
    <form class="card" action="/enroll.mobileconfig" method="get">
      <input type="hidden" name="k" value="${esc(code)}">
      <label>Votre prénom <input name="n" required maxlength="40" placeholder="ex. Marie"></label>
      <button class="btn">Obtenir le profil</button>
      <ol>
        <li>Touchez « Autoriser » quand Safari propose de télécharger le profil.</li>
        <li>Ouvrez <b>Réglages</b> → <b>Profil téléchargé</b> (tout en haut) → <b>Installer</b>.</li>
        <li>Safari rouvre cette page et affiche l'identifiant de l'iPhone. Il est ajouté automatiquement.</li>
      </ol>
      <small>Le profil ne modifie aucun réglage : il sert seulement à lire l'identifiant, puis disparaît.</small>
    </form>
    <h2>2. Installer les apps</h2>
    <div class="card">${apps}</div>
    <small>Si l'installation échoue (« Impossible d'installer »), l'iPhone n'est pas encore autorisé : attendez que
    l'étape 1 affiche « Prêt », puis réessayez. L'icône apparaît sur l'écran d'accueil pendant le téléchargement.</small>
  `);
}

async function udidPage(env, url, code) {
  const udid = url.searchParams.get("u") || "";
  const device = await readJson(env, `devices/${udid}.json`);
  const res = page("Mon iPhone", `
    <h1>Mon iPhone</h1>
    <div class="card">
      <p>Identifiant (UDID) :</p>
      <p><code id="u">${esc(udid)}</code></p>
      <button class="btn" onclick="navigator.clipboard.writeText(document.getElementById('u').textContent)">Copier</button>
      ${device ? `<p>${esc(device.name)} · ${esc(device.product || "")}</p><p>${statusLine(device)}</p>` : "<p>Appareil inconnu.</p>"}
    </div>
    <p><a class="btn" href="/?k=${encodeURIComponent(code)}">Retour aux apps</a></p>
    ${device && device.status !== "ready" ? `<script>setTimeout(() => location.reload(), 20000)</script><small>Cette page se met à jour toute seule.</small>` : ""}
  `);
  if (device) res.headers.append("set-cookie", cookieHeader("udid", udid));
  return res;
}

function loginPage(url, wrong) {
  return page("Apps de la famille", `
    <h1>Apps de la famille</h1>
    <form class="card" method="get" action="/">
      <label>Code familial <input name="k" type="password" required autocomplete="current-password"></label>
      ${wrong ? `<p class="err">Code incorrect.</p>` : ""}
      <button class="btn">Entrer</button>
    </form>`, wrong ? 403 : 200);
}

function page(title, body, status = 200) {
  return new Response(`<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<title>${esc(title)}</title><style>
:root{color-scheme:light dark;--bg:#f4f4f6;--card:#fff;--fg:#111;--mut:#666;--acc:#e00}
@media (prefers-color-scheme:dark){:root{--bg:#111;--card:#1c1c1e;--fg:#eee;--mut:#999}}
body{margin:0;padding:16px;font:16px/1.45 -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--fg);max-width:640px;margin-inline:auto}
h1{font-size:1.5em}h2{font-size:1.1em;margin-top:1.6em}small{color:var(--mut);display:block}
.card{background:var(--card);border-radius:14px;padding:14px 16px;margin:10px 0}
.app{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:8px 0;border-bottom:1px solid #8883}
.app:last-child{border-bottom:0}
.btn{display:inline-block;background:var(--acc);color:#fff;border:0;border-radius:10px;padding:10px 16px;font:inherit;font-weight:600;text-decoration:none;white-space:nowrap}
input{display:block;width:100%;box-sizing:border-box;margin:6px 0 12px;padding:10px;border-radius:10px;border:1px solid #8886;font:inherit;background:transparent;color:inherit}
code{word-break:break-all;font-size:1.05em}.err{color:var(--acc)}ol{padding-left:1.2em}
</style></head><body>${body}</body></html>`, { status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
}

// ------------------------------------------------------------------ utilitaires

async function readJson(env, key) {
  const obj = await env.BUCKET.get(key);
  return obj ? JSON.parse(await obj.text()) : null;
}

function safeEqual(a, b) {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function cookie(request, name) {
  const m = (request.headers.get("cookie") || "").match(new RegExp(`(?:^|;\\s*)${name}=([^;]*)`));
  return m ? decodeURIComponent(m[1]) : null;
}

function cookieHeader(name, value) {
  return `${name}=${encodeURIComponent(value)}; Path=/; Max-Age=31536000; Secure; HttpOnly; SameSite=Lax`;
}

function withCookie(res, setCookie) {
  if (setCookie) res.headers.append("set-cookie", setCookie);
  return res;
}

const text = (s, status = 200) => new Response(s, { status, headers: { "content-type": "text/plain; charset=utf-8" } });
const json = (o) => new Response(JSON.stringify(o), { headers: { "content-type": "application/json" } });
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const xml = esc;
const unxml = (s) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'").replace(/&amp;/g, "&");

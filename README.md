# yt-famille

Builds personnels de YouTube modifié, pour moi et ma famille. **Usage non commercial, dépôt privé, aucune redistribution.**

Le dépôt ne contient **aucun binaire** (ni APK, ni IPA, ni clé) : seulement la configuration et les workflows. Les apps produites sont publiées dans les *Releases* de ce dépôt privé.

| Plateforme | Patchs | Moteur | Déclenchement |
|---|---|---|---|
| Android 16+ (sans root) | [Morphe](https://github.com/MorpheApp/morphe-patches) (successeur actif de ReVanced) | [j-hc/revanced-magisk-module](https://github.com/j-hc/revanced-magisk-module) | Chaque jour, build seulement si les patchs ou `config.toml` changent |
| iOS 26+ | [uYouEnhanced](https://github.com/arichornlover/uYouEnhanced) | Theos + [cyan](https://github.com/asdfzxcvbn/pyzule-rw) | Chaque lundi, build seulement si l'IPA ou uYouEnhanced change |

Tous les workflows peuvent aussi être lancés à la main : onglet **Actions** → workflow → **Run workflow**.

---

## Android

### Comment ça marche
1. Le workflow lit la dernière version des patchs Morphe.
2. Il choisit la **version de YouTube la plus récente supportée par les patchs** (`version = "experimental"`, voir `config.toml`).
3. Il télécharge l'APK officiel (APKMirror, sinon archive.org) et **vérifie qu'il est signé par Google**.
4. Il applique les patchs, signe avec **notre propre clé**, et publie l'APK + MicroG-RE dans une release.

### Clé de signature
Toutes les mises à jour doivent être signées avec la même clé, sinon Android refuse de les installer.
Au premier build, une clé est générée et rangée dans une release **brouillon** `android-signing-key` (visible seulement par les administrateurs du dépôt). **Ne pas la supprimer.**

Pour plus de sécurité, on peut la déplacer dans un secret :
1. Télécharger `ks.p12` depuis la release brouillon.
2. `base64 -w0 ks.p12` → créer le secret `ANDROID_KEYSTORE_B64` (Settings → Secrets and variables → Actions).
3. Supprimer la release brouillon.

### Noms des apps
Les apps s'appellent **YouThibz** (YouTube) et **YThibz Music** (YouTube Music), avec le **logo d'origine** : option `patcher-args` du patch « Custom branding » dans `config.toml`.

### Installer sur un téléphone
1. **Première fois :** installer `MicroG-RE` (nécessaire pour se connecter au compte Google sans root), puis `youtube-morphe-…apk`.
2. Ouvrir YouTube → se connecter → MicroG-RE gère la connexion.
3. **Mises à jour :** installer le nouvel APK YouTube par-dessus l'ancien (les données sont conservées).

L'app installée s'appelle YouTube mais a un nom de paquet différent : elle cohabite avec le YouTube officiel (qu'on peut désactiver).

### Personnaliser
Modifier `config.toml` (patchs exclus, options, `patches-version = "dev"` pour des versions de YouTube plus récentes mais moins testées).

---

## iOS

### 1. Fournir l'IPA déchiffrée (à chaque nouvelle version de YouTube)
1. **Releases → Draft a new release**, titre **ou** tag : `ios-source`.
2. Joindre l'IPA déchiffrée de YouTube (fichier `.ipa`), puis **Save draft**.
3. Pour mettre à jour YouTube plus tard : éditer ce brouillon, supprimer l'ancienne IPA, joindre la nouvelle.

Ensuite : **Actions → iOS → Run workflow** (ou attendre le lundi suivant).

**Vérification automatique :** avant chaque build, `scripts/verify_ipa.py` refuse une IPA encore **chiffrée** ou **déjà modifiée** (uYou, YTLite, CydiaSubstrate…). Pour seulement tester une IPA sans rien construire : **Run workflow** avec `verify_only` coché (quelques minutes Linux, pas de minutes macOS).

> ⚠️ uYouEnhanced est testé avec une version précise de YouTube (indiquée dans les notes de chaque release). Une IPA beaucoup plus récente peut marcher, avec parfois des fonctions cassées.

### 2. Installer avec le compte développeur Apple (99 $/an)
L'IPA publiée n'est **pas signée**. Le plus simple :
- **[Sideloadly](https://sideloadly.io)** (Windows/macOS) : brancher l'iPhone/iPad, choisir l'IPA, se connecter avec l'Apple ID développeur. Avec un compte payant, l'app est valable **1 an** (au lieu de 7 jours).
- Chaque appareil de la famille est enregistré automatiquement dans le compte développeur (jusqu'à 100 iPhone par an).
- Activer le **Mode développeur** sur l'appareil (Réglages → Confidentialité et sécurité) quand iOS le demande.

### Options du workflow
- `sponsorblock` (activé par défaut), `ytuhd` (4K VP9, désactivé par défaut)
- `app_name`, `bundle_id`
- `ipa_url` : utiliser une URL directe au lieu de la release `ios-source`

---

## Releases
Seule la **dernière** release de chaque app est gardée (workflows + **Nettoyage des releases** chaque dimanche, lançable à la main). Les brouillons (`android-signing-key`, `ios-source`, `ytmusic-source`) ne sont jamais supprimés.

## Coûts GitHub Actions (dépôt privé, offre gratuite : 2000 min/mois)
- Android : ~1 min/jour de vérification + ~10 min par build.
- iOS : les minutes macOS comptent **x10** (~15 min réelles = ~150 min). La vérification se fait sur Linux, et un build n'a lieu que si quelque chose a changé.

## Règles
- Garder ce dépôt **privé**. Ne jamais partager publiquement les APK/IPA produits.
- Modifier YouTube est contraire à ses conditions d'utilisation : risque faible mais non nul pour les comptes.

---

## iOS — « YouThibz » (notre propre tweak, en construction)

Dossier `tweak-ios/`, workflow **YouThibz** (compilé sous Linux, bien moins cher en minutes que macOS).

- `vendor.lock` : briques open source figées à un commit (YouTube-X : pubs + arrière-plan, YouPiP, YouQuality, iSponsorBlock, Return-YouTube-Dislikes).
- `Sources/` : notre code (masquer les Shorts, qualité par défaut Wi-Fi 1080p / mobile 720p), réglable dans **YouTube > Réglages > YouThibz**.
- L'app s'appelle **« YouThibz »** avec un bundle ID distinct : elle s'installe **à côté** de l'app uYouEnhanced pour comparer.
- Chaque modification de `tweak-ios/` relance automatiquement un build.

### Suivre les mises à jour de YouTube
À chaque build, `scripts/check_hooks.py` compare ce que modifient les tweaks (classes et méthodes « hookées ») avec le contenu réel de l'IPA (extrait avec [ipsw](https://github.com/blacktop/ipsw)).
Le rapport **« Compatibilité des hooks »** apparaît dans les notes de chaque release YouThibz et dans le résumé du workflow : c'est la liste de ce qu'il faut adapter quand une nouvelle version de YouTube casse quelque chose.

---

## YouTube Music

### Android
Construit avec YouTube dans le workflow **Android** (patchs Morphe, section `[Music]` de `config.toml`). La release contient `music-…apk` ; **MicroG-RE** sert aux deux apps.

### iOS
Workflow **YouTube Music iOS** : [YTMusicUltimate](https://github.com/dayanch96/YTMusicUltimate) (GPL-3 : pubs, arrière-plan, téléchargements, SponsorBlock…), compilé sous Linux avec le correctif de connexion pour le sideload, figé dans `ytmusic-ios/vendor.lock`.
1. **Releases → Draft a new release**, titre **ou** tag : `ytmusic-source`, joindre l'IPA **déchiffrée** de YouTube Music, **Save draft**.
2. **Actions → YouTube Music iOS → Run workflow** (ou attendre le lundi).
3. Installer l'IPA produite avec Sideloadly, comme pour YouTube.

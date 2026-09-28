// Briques open source chargées par YouThibz au démarrage (voir Loader.x).
// Chaque brique peut être désactivée dans Réglages > YouThibz (effet au prochain lancement).
#import "Prefs.h"

// { nom du fichier .dylib (sans extension), titre, description }
static inline NSArray <NSArray <NSString *> *> *YTBModules(void) {
    return @[
        @[@"YouTubeX", @"Pubs bloquées + arrière-plan", @"YouTube-X : retire les pubs et permet la lecture écran verrouillé."],
        @[@"YouPiP", @"Image dans l'image", @"YouPiP : la vidéo continue dans une petite fenêtre hors de l'app."],
        @[@"YouQuality", @"Bouton qualité", @"YouQuality : bouton de choix de qualité dans le lecteur."],
        @[@"iSponsorBlock", @"SponsorBlock", @"Saute automatiquement les passages sponsorisés."],
        @[@"YouTubeDislikesReturn", @"Retour des « Je n'aime pas »", @"Return YouTube Dislike : affiche le nombre de « Je n'aime pas »."],
        @[@"IAmYouTube", @"Connexion Google", @"IAmYouTube : permet de se connecter à son compte. Le désactiver peut vous déconnecter."],
    ];
}

static inline NSString *YTBModuleKey(NSString *dylib) {
    return [@"module_" stringByAppendingString:dylib];
}

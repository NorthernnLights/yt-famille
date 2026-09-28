// Réglages de YouThibz, stockés dans NSUserDefaults avec le préfixe « YouThibz_ ».
// Modifiables dans YouTube > Réglages > YouThibz ; sinon les valeurs par défaut ci-dessous s'appliquent.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#define YTB_KEY(k) [@"YouThibz_" stringByAppendingString:(k)]

static inline BOOL YTBBool(NSString *key, BOOL fallback) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:YTB_KEY(key)];
    return value ? [value boolValue] : fallback;
}

static inline NSInteger YTBInt(NSString *key, NSInteger fallback) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:YTB_KEY(key)];
    return value ? [value integerValue] : fallback;
}

// Clés et valeurs par défaut
#define kHideShorts        @"hideShorts"        // BOOL, défaut YES
#define kQualityWiFi       @"qualityWiFi"       // hauteur max en pixels (0 = ne rien changer), défaut 1080
#define kQualityCellular   @"qualityCellular"   // idem en données mobiles, défaut 720

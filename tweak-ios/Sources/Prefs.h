// Réglages de YTPerso, stockés dans NSUserDefaults avec le préfixe « YTPerso_ ».
// Tant qu'il n'y a pas d'écran de réglages, les valeurs par défaut ci-dessous s'appliquent.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#define YTP_KEY(k) [@"YTPerso_" stringByAppendingString:(k)]

static inline BOOL YTPBool(NSString *key, BOOL fallback) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:YTP_KEY(key)];
    return value ? [value boolValue] : fallback;
}

static inline NSInteger YTPInt(NSString *key, NSInteger fallback) {
    id value = [[NSUserDefaults standardUserDefaults] objectForKey:YTP_KEY(key)];
    return value ? [value integerValue] : fallback;
}

// Clés et valeurs par défaut
#define kHideShorts        @"hideShorts"        // BOOL, défaut YES
#define kQualityWiFi       @"qualityWiFi"       // hauteur max en pixels (0 = ne rien changer), défaut 1080
#define kQualityCellular   @"qualityCellular"   // idem en données mobiles, défaut 720

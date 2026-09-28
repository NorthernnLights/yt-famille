// Qualité par défaut : à chaque vidéo, choisir la meilleure qualité qui ne dépasse pas
// le plafond réglé (différent en Wi-Fi et en données mobiles).
#import "Prefs.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <netinet/in.h>
#import <YouTubeHeader/MLFormat.h>
#import <YouTubeHeader/MLQuickMenuVideoQualitySettingFormatConstraint.h>
#import <YouTubeHeader/YTPlayerViewController.h>
#import <YouTubeHeader/YTSingleVideoController.h>

@interface YTSingleVideoController (YouThibz)
- (void)setVideoFormatConstraint:(id)constraint;
@end

static BOOL YTBOnCellular(void) {
    struct sockaddr_in zero = { .sin_len = sizeof(zero), .sin_family = AF_INET };
    SCNetworkReachabilityRef ref = SCNetworkReachabilityCreateWithAddress(NULL, (const struct sockaddr *)&zero);
    if (!ref) return NO;
    SCNetworkReachabilityFlags flags = 0;
    BOOL ok = SCNetworkReachabilityGetFlags(ref, &flags);
    CFRelease(ref);
    return ok && (flags & kSCNetworkReachabilityFlagsIsWWAN);
}

static void YTBApplyDefaultQuality(YTPlayerViewController *player) {
    if (!player) return;
    // Seulement le lecteur principal (pas les Shorts ni les aperçus muets).
    if (![player.view.superview isKindOfClass:NSClassFromString(@"YTWatchView")]) return;

    NSInteger cap = YTBOnCellular() ? YTBInt(kQualityCellular, 720) : YTBInt(kQualityWiFi, 1080);
    if (cap <= 0) return;

    YTSingleVideoController *video = [player activeVideo];
    if (![video respondsToSelector:@selector(setVideoFormatConstraint:)]) return;

    MLFormat *best = nil, *lowest = nil;
    for (MLFormat *format in [video selectableVideoFormats]) {
        int res = [format singleDimensionResolution];
        if (!lowest || res < [lowest singleDimensionResolution]) lowest = format;
        if (res > cap) continue;
        if (!best || res > [best singleDimensionResolution]
            || (res == [best singleDimensionResolution] && [format FPS] > [best FPS])) best = format;
    }
    MLFormat *chosen = best ?: lowest;
    if (!chosen) return;

    Class constraintClass = NSClassFromString(@"MLQuickMenuVideoQualitySettingFormatConstraint");
    if (![constraintClass instancesRespondToSelector:@selector(initWithVideoQualitySetting:formatSelectionReason:qualityLabel:)]) return;
    id constraint = [[constraintClass alloc] initWithVideoQualitySetting:3 formatSelectionReason:2 qualityLabel:[chosen qualityLabel]];
    [video setVideoFormatConstraint:constraint];
}

%hook YTPlayerViewController
- (void)loadWithPlayerTransition:(id)transition playbackConfig:(id)config {
    %orig;
    __weak YTPlayerViewController *weakSelf = self;
    // Laisser le temps au lecteur de connaître les formats disponibles.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTBApplyDefaultQuality(weakSelf);
    });
}
%end

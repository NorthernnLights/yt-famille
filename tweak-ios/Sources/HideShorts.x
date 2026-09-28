// Masquer les Shorts : étagères du fil, cellules isolées et onglet de la barre du bas.
#import "Prefs.h"
#import <YouTubeHeader/YTIElementRenderer.h>
#import <YouTubeHeader/YTIPivotBarRenderer.h>

@interface YTPivotBarView : UIView
- (void)setRenderer:(YTIPivotBarRenderer *)renderer;
@end

// Identifiants des éléments « Shorts » dans les réponses du serveur.
static BOOL YTBIsShortsElement(NSString *description) {
    if ([description containsString:@"history*"]) return NO; // garder l'historique intact
    for (NSString *marker in @[@"shorts_shelf.eml", @"shorts_video_cell.eml", @"6Shorts"]) {
        if ([description containsString:marker]) return YES;
    }
    return NO;
}

%hook YTIElementRenderer
- (NSData *)elementData {
    if (YTBBool(kHideShorts, YES) && YTBIsShortsElement([self description])) return nil;
    return %orig;
}
%end

%hook YTPivotBarView
- (void)setRenderer:(YTIPivotBarRenderer *)renderer {
    if (YTBBool(kHideShorts, YES)) {
        NSMutableArray <YTIPivotBarSupportedRenderers *> *items = [renderer itemsArray];
        NSIndexSet *shorts = [items indexesOfObjectsPassingTest:^BOOL(YTIPivotBarSupportedRenderers *item, NSUInteger idx, BOOL *stop) {
            return [[[item pivotBarItemRenderer] pivotIdentifier] isEqualToString:@"FEshorts"];
        }];
        [items removeObjectsAtIndexes:shorts];
    }
    %orig;
}
%end

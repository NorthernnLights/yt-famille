// Section « YouThibz » dans les réglages de YouTube (Réglages > YouThibz).
#import "Prefs.h"
#import <objc/runtime.h>
#import <YouTubeHeader/YTIIcon.h>
#import <YouTubeHeader/YTIcon.h>
#import <YouTubeHeader/YTSettingsCell.h>
#import <YouTubeHeader/YTSettingsGroupData.h>
#import <YouTubeHeader/YTSettingsPickerViewController.h>
#import <YouTubeHeader/YTSettingsSectionItem.h>
#import <YouTubeHeader/YTSettingsSectionItemManager.h>
#import <YouTubeHeader/YTSettingsViewController.h>

static const NSInteger kYouThibzSection = 'ytbz';

@interface YTSettingsSectionItemManager (YouThibz)
- (void)updateYouThibzSectionWithEntry:(id)entry;
@end

@interface YTSettingsGroupData (YouThibz)
+ (NSMutableArray <NSNumber *> *)tweaks; // présent seulement si YouGroupSettings est installé
@end

static void YTBSetValue(NSString *key, id value) {
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:YTB_KEY(key)];
}

static NSString *YTBQualityLabel(NSInteger height) {
    return height <= 0 ? @"Automatique (choix de YouTube)" : [NSString stringWithFormat:@"%ldp maximum", (long)height];
}

// Ligne « qualité » qui ouvre une liste de choix.
static YTSettingsSectionItem *YTBQualityItem(YTSettingsViewController *settings, NSString *title, NSString *key, NSInteger fallback) {
    Class itemClass = objc_getClass("YTSettingsSectionItem");
    NSArray <NSNumber *> *choices = @[@0, @2160, @1440, @1080, @720, @480, @360];
    __weak YTSettingsViewController *weakSettings = settings;
    return [itemClass itemWithTitle:title
        titleDescription:nil
        accessibilityIdentifier:nil
        detailTextBlock:^NSString *() {
            return YTBQualityLabel(YTBInt(key, fallback));
        }
        selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger index) {
            NSMutableArray <YTSettingsSectionItem *> *rows = [NSMutableArray array];
            for (NSNumber *height in choices) {
                [rows addObject:[itemClass checkmarkItemWithTitle:YTBQualityLabel(height.integerValue) selectBlock:^BOOL (YTSettingsCell *c, NSUInteger i) {
                    YTBSetValue(key, height);
                    [weakSettings reloadData];
                    return YES;
                }]];
            }
            NSUInteger selected = [choices indexOfObject:@(YTBInt(key, fallback))];
            YTSettingsPickerViewController *picker = [[objc_getClass("YTSettingsPickerViewController") alloc]
                initWithNavTitle:title
                pickerSectionTitle:nil
                rows:rows
                selectedItemIndex:(selected == NSNotFound ? 0 : selected)
                parentResponder:[weakSettings parentResponder]];
            [weakSettings pushViewController:picker];
            return YES;
        }];
}

%hook YTSettingsSectionItemManager

%new(v@:@)
- (void)updateYouThibzSectionWithEntry:(id)entry {
    YTSettingsViewController *settings = [self valueForKey:@"_dataDelegate"];
    Class itemClass = objc_getClass("YTSettingsSectionItem");
    NSMutableArray <YTSettingsSectionItem *> *items = [NSMutableArray array];

    [items addObject:[itemClass switchItemWithTitle:@"Masquer les Shorts"
        titleDescription:@"Retire les Shorts du fil et l'onglet Shorts. Effet complet au prochain lancement de l'app."
        accessibilityIdentifier:nil
        switchOn:YTBBool(kHideShorts, YES)
        switchBlock:^BOOL (YTSettingsCell *cell, BOOL on) {
            YTBSetValue(kHideShorts, @(on));
            return YES;
        }
        settingItemId:0]];
    [items addObject:YTBQualityItem(settings, @"Qualité en Wi-Fi", kQualityWiFi, 1080)];
    [items addObject:YTBQualityItem(settings, @"Qualité en données mobiles", kQualityCellular, 720)];

    if ([settings respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)]) {
        YTIIcon *icon = [objc_getClass("YTIIcon") new];
        icon.iconType = YT_TUNE;
        [settings setSectionItems:items forCategory:kYouThibzSection title:@"YouThibz" icon:icon titleDescription:nil headerHidden:NO];
    } else {
        [settings setSectionItems:items forCategory:kYouThibzSection title:@"YouThibz" titleDescription:nil headerHidden:NO];
    }
}

- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category == kYouThibzSection) {
        [self updateYouThibzSectionWithEntry:entry];
        return;
    }
    %orig;
}

%end

// Anciennes versions de YouTube : liste plate de catégories.
%hook YTAppSettingsPresentationData
+ (NSArray <NSNumber *> *)settingsCategoryOrder {
    NSArray <NSNumber *> *order = %orig;
    NSUInteger index = [order indexOfObject:@(1)];
    if (index == NSNotFound || [order containsObject:@(kYouThibzSection)]) return order;
    NSMutableArray <NSNumber *> *mutableOrder = [order mutableCopy];
    [mutableOrder insertObject:@(kYouThibzSection) atIndex:index + 1];
    return mutableOrder;
}
%end

// Versions récentes : réglages regroupés, on se place en tête du premier groupe.
%hook YTSettingsGroupData
- (NSArray <NSNumber *> *)orderedCategories {
    NSArray <NSNumber *> *categories = %orig;
    if (self.type != 1 || [categories containsObject:@(kYouThibzSection)]) return categories;
    if (class_getClassMethod(objc_getClass("YTSettingsGroupData"), @selector(tweaks))) {
        NSMutableArray <NSNumber *> *tweaks = [objc_getClass("YTSettingsGroupData") tweaks];
        if (![tweaks containsObject:@(kYouThibzSection)]) [tweaks insertObject:@(kYouThibzSection) atIndex:0];
        return categories;
    }
    NSMutableArray <NSNumber *> *mutableCategories = [categories mutableCopy];
    [mutableCategories insertObject:@(kYouThibzSection) atIndex:0];
    return mutableCategories;
}
%end

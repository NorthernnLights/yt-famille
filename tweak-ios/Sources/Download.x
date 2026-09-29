// Téléchargement de vidéos : bouton ⬇︎ dans le lecteur (via YTVideoOverlay, comme YouPiP et YouQuality).
//  - « Vidéo » : H.264 sous le plafond de qualité + audio AAC, assemblés en .mp4 et enregistrés dans Photos.
//  - « Audio seul » : .m4a enregistré dans Fichiers > Sur mon iPhone > YouThibz.
// Les téléchargements tournent en arrière-plan (plusieurs à la fois) : une pastille en bas de l'écran
// indique la progression, la toucher permet d'en annuler ; un bandeau signale la fin.
//
// Sources des liens, dans l'ordre :
//  1. liens directs de la réponse reçue par l'app (rares : l'app lit en « SABR ») ;
//  2. flux HLS de cette réponse (autorisé par le compte connecté) : listes de lecture analysées ici,
//     fragments MP4 téléchargés puis assemblés (pas d'outil externe) ;
//  3. nouvelle demande à l'API InnerTube avec un autre client (YTBInnerTubeClients), sans compte.
#import "Prefs.h"
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <YouTubeHeader/MLFormat.h>
#import <YouTubeHeader/MLVideo.h>
#import <YouTubeHeader/YTInlinePlayerBarContainerView.h>
#import <YouTubeHeader/YTMainAppControlsOverlayView.h>
#import <YouTubeHeader/YTPlayerViewController.h>
#import <YouTubeHeader/YTQTMButton.h>
#import <YouTubeHeader/YTSingleVideoController.h>

#define kDownloadButton @"YouThibzDownload"
#define kDownloadEnabled YTB_KEY(kDownloadButtonPref) // lue par YTVideoOverlay pour afficher le bouton

// --- API de YTVideoOverlay (github.com/PoomSmart/YTVideoOverlay, Init.h) -------------------------
@interface YTSettingsSectionItemManager_YTVO : NSObject
+ (void)registerTweak:(NSString *)tweakId metadata:(NSDictionary *)metadata;
@end

@interface YTMainAppControlsOverlayView (YouThibz)
@property (retain, nonatomic) NSMutableDictionary <NSString *, YTQTMButton *> *overlayButtons;
- (void)didPressYouThibzDownload:(id)arg;
@end

@interface YTInlinePlayerBarContainerView (YouThibz)
@property (retain, nonatomic) NSMutableDictionary <NSString *, YTQTMButton *> *overlayButtons;
- (void)didPressYouThibzDownload:(id)arg;
@end

// --- Outils ------------------------------------------------------------------------------------

static __weak YTPlayerViewController *YTBLastPlayer;

static id YTBValue(id object, NSString *key) {
    if (!object) return nil;
    @try { return [object valueForKey:key]; } @catch (NSException *e) { return nil; }
}

static UIWindow *YTBKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) return w;
    }
    return nil;
}

static UIViewController *YTBTopController(void) {
    UIViewController *vc = YTBKeyWindow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void YTBAlert(NSString *title, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [YTBTopController() presentViewController:alert animated:YES completion:nil];
    });
}

static NSError *YTBError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"YouThibz" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static YTPlayerViewController *YTBPlayerFrom(UIResponder *responder) {
    if ([responder respondsToSelector:@selector(playerViewController)]) {
        id player = [(id)responder playerViewController];
        if ([player isKindOfClass:NSClassFromString(@"YTPlayerViewController")]) return player;
    }
    for (UIResponder *r = responder; r; r = r.nextResponder)
        if ([r isKindOfClass:NSClassFromString(@"YTPlayerViewController")]) return (YTPlayerViewController *)r;
    return YTBLastPlayer;
}

static NSString *YTBSafeFileName(NSString *name) {
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>\n\r\t"];
    NSString *clean = [[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"-"];
    clean = [clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (clean.length > 80) clean = [clean substringToIndex:80];
    return clean.length ? clean : @"video";
}

static NSString *YTBAppUserAgent(void) {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *ios = [UIDevice.currentDevice.systemVersion stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    return [NSString stringWithFormat:@"com.google.ios.youtube/%@ (iPhone; U; CPU iOS %@ like Mac OS X)", version, ios];
}

static NSURLSession *YTBSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 60;
        config.HTTPMaximumConnectionsPerHost = 6;
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
}

// --- Suivi des téléchargements : pastille, liste, bandeaux ------------------------------------------

@interface YTBJob : NSObject
@property (nonatomic, copy) NSString *title, *phase;
@property (nonatomic) BOOL audioOnly;
@property (nonatomic) double progress;
@property (atomic) BOOL cancelled;
@property (nonatomic, copy) NSString *directory;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundTask;
@end
@implementation YTBJob
@end

@interface YTBCenter : NSObject
@property (nonatomic, strong) NSMutableArray <YTBJob *> *jobs;
@property (nonatomic, strong) UIButton *pill;
+ (instancetype)shared;
- (void)refresh;
- (void)toast:(NSString *)text;
@end

@implementation YTBCenter
+ (instancetype)shared {
    static YTBCenter *center;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ center = [YTBCenter new]; center.jobs = [NSMutableArray array]; });
    return center;
}

- (void)add:(YTBJob *)job {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.jobs addObject:job];
        job.backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
            [UIApplication.sharedApplication endBackgroundTask:job.backgroundTask];
            job.backgroundTask = UIBackgroundTaskInvalid;
        }];
        [self refresh];
    });
}

- (void)remove:(YTBJob *)job {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.jobs removeObject:job];
        if (job.directory) [[NSFileManager defaultManager] removeItemAtPath:job.directory error:nil];
        if (job.backgroundTask != UIBackgroundTaskInvalid) [UIApplication.sharedApplication endBackgroundTask:job.backgroundTask];
        job.backgroundTask = UIBackgroundTaskInvalid;
        [self refresh];
    });
}

- (void)refresh {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; }); return; }
    UIWindow *window = YTBKeyWindow();
    if (!self.jobs.count || !window) { [self.pill removeFromSuperview]; return; }
    if (!self.pill) {
        UIButton *pill = [UIButton buttonWithType:UIButtonTypeSystem];
        pill.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.9];
        pill.tintColor = UIColor.whiteColor;
        pill.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
        pill.layer.cornerRadius = 18;
        [pill addTarget:self action:@selector(showList) forControlEvents:UIControlEventTouchUpInside];
        self.pill = pill;
    }
    double total = 0;
    for (YTBJob *job in self.jobs) total += job.progress;
    NSString *text = self.jobs.count == 1
        ? [NSString stringWithFormat:@"⬇︎ %@ · %d %%", self.jobs.firstObject.phase ?: @"Téléchargement", (int)(total * 100)]
        : [NSString stringWithFormat:@"⬇︎ %lu téléchargements · %d %%", (unsigned long)self.jobs.count, (int)(total / self.jobs.count * 100)];
    [self.pill setTitle:text forState:UIControlStateNormal];
    [self.pill sizeToFit];
    CGFloat width = MIN(self.pill.bounds.size.width + 32, window.bounds.size.width - 32);
    self.pill.frame = CGRectMake((window.bounds.size.width - width) / 2,
                                 window.bounds.size.height - window.safeAreaInsets.bottom - 110, width, 36);
    if (self.pill.superview != window) [window addSubview:self.pill];
    [window bringSubviewToFront:self.pill];
}

- (void)showList {
    UIAlertController *list = [UIAlertController alertControllerWithTitle:@"Téléchargements" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSMutableArray <NSString *> *lines = [NSMutableArray array];
    for (YTBJob *job in [self.jobs copy]) {
        [lines addObject:[NSString stringWithFormat:@"%@ — %@ %d %%", job.title, job.phase ?: @"", (int)(job.progress * 100)]];
        NSString *short_ = job.title.length > 30 ? [[job.title substringToIndex:30] stringByAppendingString:@"…"] : job.title;
        [list addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Annuler « %@ »", short_] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            job.cancelled = YES;
        }]];
    }
    list.message = [lines componentsJoinedByString:@"\n"];
    [list addAction:[UIAlertAction actionWithTitle:@"Fermer" style:UIAlertActionStyleCancel handler:nil]];
    list.popoverPresentationController.sourceView = self.pill;
    list.popoverPresentationController.sourceRect = self.pill.bounds;
    [YTBTopController() presentViewController:list animated:YES completion:nil];
}

- (void)toast:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = YTBKeyWindow();
        if (!window) return;
        UILabel *label = [UILabel new];
        label.text = text;
        label.numberOfLines = 3;
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        label.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.92];
        label.layer.cornerRadius = 14;
        label.clipsToBounds = YES;
        CGFloat width = window.bounds.size.width - 40;
        CGSize size = [label sizeThatFits:CGSizeMake(width - 24, CGFLOAT_MAX)];
        label.frame = CGRectMake(20, window.safeAreaInsets.top + 8, width, size.height + 20);
        label.alpha = 0;
        [window addSubview:label];
        [UIView animateWithDuration:0.25 animations:^{ label.alpha = 1; } completion:^(BOOL f) {
            [UIView animateWithDuration:0.4 delay:3.5 options:0 animations:^{ label.alpha = 0; } completion:^(BOOL f2) { [label removeFromSuperview]; }];
        }];
    });
}
@end

static NSError *YTBCancelledError(void) { return YTBError(-999, @"Annulé"); }

// --- Formats disponibles -----------------------------------------------------------------------

@interface YTBFormat : NSObject
@property (nonatomic, copy) NSString *url, *mime, *userAgent; // userAgent : celui du client qui a fourni le lien
@property (nonatomic) NSInteger itag, height, bitrate;
@property (nonatomic) long long length;
@property (nonatomic) double fps;
@property (nonatomic) BOOL defaultAudio;
@end
@implementation YTBFormat
- (BOOL)isVideoH264 { return [self.mime hasPrefix:@"video/mp4"] && [self.mime containsString:@"avc1"]; }
- (BOOL)isAudioAAC { return [self.mime hasPrefix:@"audio/mp4"]; }
- (BOOL)isMuxed { return [self.mime hasPrefix:@"video/mp4"] && [self.mime containsString:@"mp4a"]; }
@end

static YTBFormat *YTBFormatFromStream(id stream) {
    YTBFormat *f = [YTBFormat new];
    id url = YTBValue(stream, @"URL");
    f.url = [url isKindOfClass:NSURL.class] ? [url absoluteString] : url;
    f.mime = YTBValue(stream, @"mimeType") ?: @"";
    f.itag = [YTBValue(stream, @"itag") integerValue];
    f.height = [YTBValue(stream, @"height") integerValue];
    f.bitrate = [YTBValue(stream, @"bitrate") integerValue];
    f.length = [YTBValue(stream, @"contentLength") longLongValue];
    f.fps = [YTBValue(stream, @"fps") doubleValue];
    id track = YTBValue(stream, @"audioTrack");
    f.defaultAudio = !track || [YTBValue(track, @"audioIsDefault") boolValue];
    return f;
}

// Réponse « player » complète reçue par l'app (compte connecté) : YTIPlayerResponse.
static id YTBPlayerData(YTSingleVideoController *active) {
    return YTBValue(YTBValue(YTBValue([active singleVideo], @"playbackData"), @"playerResponse"), @"playerData");
}

static NSArray <YTBFormat *> *YTBFormats(YTSingleVideoController *active, NSString **diagnostic, NSString **hls) {
    NSMutableArray <YTBFormat *> *formats = [NSMutableArray array];
    id streaming = YTBValue(YTBPlayerData(active), @"streamingData");
    if (!streaming) streaming = YTBValue(YTBValue(YTBValue([active singleVideo], @"video"), @"streamingData"), @"streamingData");
    id hlsURL = YTBValue(streaming, @"hlsManifestURL");
    BOOL hasHLS = [hlsURL isKindOfClass:NSString.class] && [(NSString *)hlsURL length];
    if (hls) *hls = hasHLS ? hlsURL : nil;
    NSMutableArray *streams = [NSMutableArray array];
    for (NSString *key in @[@"adaptiveFormatsArray", @"formatsArray"]) {
        id list = YTBValue(streaming, key);
        if ([list isKindOfClass:NSArray.class]) [streams addObjectsFromArray:list];
    }
    NSUInteger withURL = 0;
    for (id stream in streams) {
        YTBFormat *f = YTBFormatFromStream(stream);
        if (f.url.length) { withURL++; f.userAgent = YTBAppUserAgent(); [formats addObject:f]; }
    }
    if (diagnostic) {
        id sabr = YTBValue(streaming, @"serverAbrStreamingURL");
        *diagnostic = [NSString stringWithFormat:@"App : réponse %@, %lu formats dont %lu avec lien, HLS %@, SABR %@.",
            YTBPlayerData(active) ? @"trouvée" : @"introuvable", (unsigned long)streams.count, (unsigned long)withURL,
            hasHLS ? @"oui" : @"non", [sabr isKindOfClass:NSString.class] && [(NSString *)sabr length] ? @"oui" : @"non"];
    }
    return formats;
}

static YTBFormat *YTBBestVideo(NSArray <YTBFormat *> *formats, NSInteger cap) {
    YTBFormat *best = nil, *lowest = nil;
    for (YTBFormat *f in formats) {
        if (![f isVideoH264] || [f isMuxed]) continue;
        if (!lowest || f.height < lowest.height) lowest = f;
        if (f.height > cap) continue;
        if (!best || f.height > best.height || (f.height == best.height && (f.fps > best.fps || (f.fps == best.fps && f.bitrate > best.bitrate))))
            best = f;
    }
    return best ?: lowest;
}

static YTBFormat *YTBBestAudio(NSArray <YTBFormat *> *formats) {
    YTBFormat *best = nil;
    for (YTBFormat *f in formats) {
        if (![f isAudioAAC]) continue;
        if (!best || (f.defaultAudio && !best.defaultAudio) || (f.defaultAudio == best.defaultAudio && f.bitrate > best.bitrate))
            best = f;
    }
    return best;
}

static YTBFormat *YTBBestMuxed(NSArray <YTBFormat *> *formats) {
    YTBFormat *best = nil;
    for (YTBFormat *f in formats)
        if ([f isMuxed] && (!best || f.height > best.height)) best = f;
    return best;
}

// --- Liens directs via l'API InnerTube (sans compte) ------------------------------------------------
// Clients et paramètres repris de yt-dlp (yt_dlp/extractor/youtube/_base.py, client sans JavaScript :
// visionos). Vérifiable avec le workflow « Sonde téléchargement YouTube » (scripts/yt_probe.py).

static NSArray <NSDictionary *> *YTBInnerTubeClients(void) {
    return @[
        @{@"name": @"visionos", @"id": @101, @"ua": @"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
          @"client": @{@"clientName": @"VISIONOS", @"clientVersion": @"1.02", @"deviceMake": @"Apple", @"deviceModel": @"RealityDevice17,1",
                       @"osName": @"visionOS", @"osVersion": @"26.5.23O471"}},
        @{@"name": @"android_vr", @"id": @28, @"ua": @"com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
          @"client": @{@"clientName": @"ANDROID_VR", @"clientVersion": @"1.65.10", @"deviceMake": @"Oculus", @"deviceModel": @"Quest 3",
                       @"androidSdkVersion": @32, @"osName": @"Android", @"osVersion": @"12L"}},
    ];
}

static NSArray <YTBFormat *> *YTBParseStreamingData(NSDictionary *streaming, NSString *userAgent) {
    NSMutableArray <YTBFormat *> *formats = [NSMutableArray array];
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *key in @[@"formats", @"adaptiveFormats"])
        if ([streaming[key] isKindOfClass:NSArray.class]) [list addObjectsFromArray:streaming[key]];
    for (NSDictionary *d in list) {
        if (![d isKindOfClass:NSDictionary.class] || ![d[@"url"] isKindOfClass:NSString.class]) continue;
        YTBFormat *f = [YTBFormat new];
        f.url = d[@"url"];
        f.mime = [d[@"mimeType"] isKindOfClass:NSString.class] ? d[@"mimeType"] : @"";
        f.itag = [d[@"itag"] integerValue];
        f.height = [d[@"height"] integerValue];
        f.bitrate = [d[@"bitrate"] integerValue];
        f.length = [d[@"contentLength"] longLongValue];
        f.fps = [d[@"fps"] doubleValue];
        NSDictionary *track = [d[@"audioTrack"] isKindOfClass:NSDictionary.class] ? d[@"audioTrack"] : nil;
        f.defaultAudio = !track || [track[@"audioIsDefault"] boolValue];
        f.userAgent = userAgent;
        [formats addObject:f];
    }
    return formats;
}

// Essaie chaque client jusqu'à obtenir des liens ; done(formats, notes) sur une file quelconque.
static void YTBFetchInnerTube(NSString *videoId, NSUInteger index, NSMutableArray <NSString *> *notes,
                              void (^done)(NSArray <YTBFormat *> *)) {
    NSArray <NSDictionary *> *clients = YTBInnerTubeClients();
    if (index >= clients.count) { done(@[]); return; }
    NSDictionary *c = clients[index];
    NSMutableDictionary *client = [c[@"client"] mutableCopy];
    NSString *lang = [[NSLocale preferredLanguages] firstObject] ?: @"fr";
    client[@"hl"] = [[lang componentsSeparatedByString:@"-"] firstObject];
    NSString *region = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    if (region) client[@"gl"] = region;
    NSDictionary *body = @{
        @"context": @{@"client": client},
        @"videoId": videoId,
        @"contentCheckOk": @YES,
        @"racyCheckOk": @YES,
        @"playbackContext": @{@"contentPlaybackContext": @{@"html5Preference": @"HTML5_PREF_WANTS"}},
    };
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.youtube.com/youtubei/v1/player?prettyPrint=false"]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:c[@"ua"] forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://www.youtube.com" forHTTPHeaderField:@"Origin"];
    [request setValue:[c[@"id"] stringValue] forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [request setValue:client[@"clientVersion"] forHTTPHeaderField:@"X-YouTube-Client-Version"];
    [[YTBSession() dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:NSDictionary.class]) json = nil;
        NSDictionary *playability = [json[@"playabilityStatus"] isKindOfClass:NSDictionary.class] ? json[@"playabilityStatus"] : nil;
        NSArray <YTBFormat *> *formats = YTBParseStreamingData([json[@"streamingData"] isKindOfClass:NSDictionary.class] ? json[@"streamingData"] : nil, c[@"ua"]);
        if (formats.count) { done(formats); return; }
        NSString *why = error.localizedDescription
            ?: [NSString stringWithFormat:@"%@ %@", playability[@"status"] ?: [NSString stringWithFormat:@"HTTP %ld", (long)[(NSHTTPURLResponse *)response statusCode]],
                playability[@"reason"] ?: @""];
        [notes addObject:[NSString stringWithFormat:@"%@ : %@", c[@"name"], why]];
        YTBFetchInnerTube(videoId, index + 1, notes, done);
    }] resume];
}

// --- Téléchargement d'un fichier par morceaux (évite le bridage de débit de YouTube) ---------------

static const long long kChunk = 10 * 1024 * 1024;

static void YTBFetchRanges(YTBJob *job, YTBFormat *format, NSFileHandle *out, long long start,
                           void (^progress)(long long bytes), void (^done)(NSError *)) {
    if (job.cancelled) { done(YTBCancelledError()); return; }
    long long end = start + kChunk - 1;
    if (format.length > 0 && end >= format.length) end = format.length - 1;
    NSString *sep = [format.url containsString:@"?"] ? @"&" : @"?";
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@range=%lld-%lld", format.url, sep, start, end]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:format.userAgent ?: YTBAppUserAgent() forHTTPHeaderField:@"User-Agent"];
    [[YTBSession() dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (!error && status == 416 && start > 0) { done(nil); return; } // taille inconnue : fin atteinte
        if (error || status >= 400) {
            done(error ?: YTBError(status, [NSString stringWithFormat:@"YouTube a refusé le téléchargement (HTTP %ld).", (long)status]));
            return;
        }
        [out writeData:data];
        long long next = start + data.length;
        progress(next);
        BOOL finished = format.length > 0 ? next >= format.length : (long long)data.length < kChunk;
        if (finished || data.length == 0) done(nil);
        else YTBFetchRanges(job, format, out, next, progress, done);
    }] resume];
}

static void YTBFetchFormat(YTBJob *job, YTBFormat *format, NSString *path, void (^progress)(double), void (^done)(NSError *)) {
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:path];
    YTBFetchRanges(job, format, out, 0, ^(long long bytes) {
        if (format.length > 0) progress((double)bytes / format.length);
    }, ^(NSError *error) {
        [out closeFile];
        done(error);
    });
}

// --- Flux HLS : listes de lecture et fragments MP4 ----------------------------------------------------
// YouTube fournit une liste principale (variantes vidéo H.264/VP9 + pistes audio séparées), chaque piste
// étant une liste de fragments MP4 précédés d'un segment d'initialisation (#EXT-X-MAP). Initialisation +
// fragments mis bout à bout forment un fichier MP4 fragmenté lisible par AVFoundation.

@interface YTBSegment : NSObject
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, copy) NSString *range; // « bytes=a-b » ou nil
@end
@implementation YTBSegment
@end

static NSDictionary <NSString *, NSString *> *YTBAttributes(NSString *line) {
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) return attrs;
    NSString *list = [line substringFromIndex:colon.location + 1];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"([A-Z0-9-]+)=(\"[^\"]*\"|[^,]*)" options:0 error:nil];
    for (NSTextCheckingResult *m in [re matchesInString:list options:0 range:NSMakeRange(0, list.length)]) {
        NSString *value = [list substringWithRange:[m rangeAtIndex:2]];
        if ([value hasPrefix:@"\""]) value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        attrs[[list substringWithRange:[m rangeAtIndex:1]]] = value;
    }
    return attrs;
}

static void YTBFetchText(NSURL *url, void (^done)(NSString *, NSError *)) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:YTBAppUserAgent() forHTTPHeaderField:@"User-Agent"];
    [[YTBSession() dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (error || status >= 400 || !text) done(nil, error ?: YTBError(status, [NSString stringWithFormat:@"liste HLS refusée (HTTP %ld)", (long)status]));
        else done(text, nil);
    }] resume];
}

// Segments d'une liste de lecture de piste : initialisation (#EXT-X-MAP) puis fragments.
static NSArray <YTBSegment *> *YTBParseMediaPlaylist(NSString *text, NSURL *base) {
    NSMutableArray <YTBSegment *> *segments = [NSMutableArray array];
    NSString *pendingRange = nil;
    __block long long nextOffset = 0;
    NSString *(^range)(NSString *) = ^NSString *(NSString *spec) { // « longueur@début »
        NSArray *parts = [spec componentsSeparatedByString:@"@"];
        long long length = [parts[0] longLongValue];
        long long offset = parts.count > 1 ? [parts[1] longLongValue] : nextOffset;
        nextOffset = offset + length;
        return [NSString stringWithFormat:@"bytes=%lld-%lld", offset, offset + length - 1];
    };
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length) continue;
        if ([line hasPrefix:@"#EXT-X-MAP:"]) {
            NSDictionary *attrs = YTBAttributes(line);
            YTBSegment *init = [YTBSegment new];
            init.url = [NSURL URLWithString:attrs[@"URI"] relativeToURL:base].absoluteURL;
            if (attrs[@"BYTERANGE"]) init.range = range(attrs[@"BYTERANGE"]);
            if (init.url) [segments insertObject:init atIndex:0];
        } else if ([line hasPrefix:@"#EXT-X-BYTERANGE:"]) {
            pendingRange = range([line substringFromIndex:17]);
        } else if (![line hasPrefix:@"#"]) {
            YTBSegment *segment = [YTBSegment new];
            segment.url = [NSURL URLWithString:line relativeToURL:base].absoluteURL;
            segment.range = pendingRange;
            pendingRange = nil;
            if (segment.url) [segments addObject:segment];
        }
    }
    return segments;
}

@interface YTBHLSChoice : NSObject
@property (nonatomic, strong) NSURL *video, *audio; // audio nil si la variante contient déjà le son
@property (nonatomic) NSInteger height;
@end
@implementation YTBHLSChoice
@end

// Choisit la variante H.264 la plus haute sous le plafond, et sa piste audio (par défaut).
static YTBHLSChoice *YTBChooseVariant(NSString *master, NSURL *base, NSInteger cap) {
    NSMutableArray <NSDictionary *> *variants = [NSMutableArray array];
    NSMutableArray <NSDictionary *> *audios = [NSMutableArray array];
    NSDictionary *pending = nil;
    for (NSString *raw in [master componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length) continue;
        if ([line hasPrefix:@"#EXT-X-MEDIA:"]) {
            NSDictionary *attrs = YTBAttributes(line);
            if ([attrs[@"TYPE"] isEqualToString:@"AUDIO"] && attrs[@"URI"]) [audios addObject:attrs];
        } else if ([line hasPrefix:@"#EXT-X-STREAM-INF:"]) {
            pending = YTBAttributes(line);
        } else if (![line hasPrefix:@"#"] && pending) {
            NSMutableDictionary *v = [pending mutableCopy];
            v[@"URL"] = line;
            [variants addObject:v];
            pending = nil;
        }
    }
    NSDictionary *best = nil, *lowest = nil;
    for (NSDictionary *v in variants) {
        if (![v[@"CODECS"] containsString:@"avc1"]) continue; // H.264 : lisible par Photos
        NSInteger height = [[[v[@"RESOLUTION"] componentsSeparatedByString:@"x"] lastObject] integerValue];
        NSInteger bandwidth = [v[@"BANDWIDTH"] integerValue];
        NSInteger lowestHeight = [[[lowest[@"RESOLUTION"] componentsSeparatedByString:@"x"] lastObject] integerValue];
        if (!lowest || height < lowestHeight) lowest = v;
        if (height > cap) continue;
        NSInteger bestHeight = [[[best[@"RESOLUTION"] componentsSeparatedByString:@"x"] lastObject] integerValue];
        if (!best || height > bestHeight || (height == bestHeight && bandwidth > [best[@"BANDWIDTH"] integerValue])) best = v;
    }
    best = best ?: lowest;
    if (!best) return nil;
    YTBHLSChoice *choice = [YTBHLSChoice new];
    choice.video = [NSURL URLWithString:best[@"URL"] relativeToURL:base].absoluteURL;
    choice.height = [[[best[@"RESOLUTION"] componentsSeparatedByString:@"x"] lastObject] integerValue];
    NSDictionary *audio = nil;
    for (NSDictionary *a in audios) {
        if (best[@"AUDIO"] && ![a[@"GROUP-ID"] isEqualToString:best[@"AUDIO"]]) continue;
        if (!audio || ([a[@"DEFAULT"] isEqualToString:@"YES"] && ![audio[@"DEFAULT"] isEqualToString:@"YES"])) audio = a;
    }
    if (audio) choice.audio = [NSURL URLWithString:audio[@"URI"] relativeToURL:base].absoluteURL;
    return choice;
}

// Télécharge les segments dans l'ordre et les met bout à bout.
static void YTBFetchSegments(YTBJob *job, NSArray <YTBSegment *> *segments, NSUInteger index, NSFileHandle *out,
                             void (^step)(void), void (^done)(NSError *)) {
    if (job.cancelled) { done(YTBCancelledError()); return; }
    if (index >= segments.count) { done(nil); return; }
    YTBSegment *segment = segments[index];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:segment.url];
    [request setValue:YTBAppUserAgent() forHTTPHeaderField:@"User-Agent"];
    if (segment.range) [request setValue:segment.range forHTTPHeaderField:@"Range"];
    [[YTBSession() dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (error || status >= 400 || !data) {
            done(error ?: YTBError(status, [NSString stringWithFormat:@"fragment %lu refusé (HTTP %ld)", (unsigned long)index, (long)status]));
            return;
        }
        [out writeData:data];
        step();
        YTBFetchSegments(job, segments, index + 1, out, step, done);
    }] resume];
}

// Télécharge une ou deux pistes HLS (vidéo, audio) ; done(cheminVidéo ou nil, cheminAudio ou nil, erreur).
static void YTBFetchHLS(YTBJob *job, NSString *manifest, NSInteger cap, void (^done)(NSString *, NSString *, NSInteger, NSError *)) {
    NSURL *masterURL = [NSURL URLWithString:manifest];
    YTBFetchText(masterURL, ^(NSString *master, NSError *error) {
        if (error) { done(nil, nil, 0, error); return; }
        YTBHLSChoice *choice = YTBChooseVariant(master, masterURL, cap);
        if (!choice) { done(nil, nil, 0, YTBError(9, @"aucune variante H.264 dans la liste HLS")); return; }
        NSURL *first = job.audioOnly ? (choice.audio ?: choice.video) : choice.video;
        NSURL *second = job.audioOnly ? nil : choice.audio;
        YTBFetchText(first, ^(NSString *firstText, NSError *error1) {
            if (error1) { done(nil, nil, 0, error1); return; }
            void (^withSecond)(NSString *) = ^(NSString *secondText) {
                NSArray <YTBSegment *> *a = YTBParseMediaPlaylist(firstText, first);
                NSArray <YTBSegment *> *b = secondText ? YTBParseMediaPlaylist(secondText, second) : @[];
                if (!a.count) { done(nil, nil, 0, YTBError(10, @"liste HLS vide")); return; }
                NSUInteger total = a.count + b.count;
                __block NSUInteger fetched = 0;
                void (^step)(void) = ^{
                    fetched++;
                    job.progress = (double)fetched / total * 0.95;
                    [[YTBCenter shared] refresh];
                };
                NSString *pathA = [job.directory stringByAppendingPathComponent:job.audioOnly ? @"audio.mp4" : @"video.mp4"];
                NSString *pathB = [job.directory stringByAppendingPathComponent:@"audio.mp4"];
                [[NSFileManager defaultManager] createFileAtPath:pathA contents:nil attributes:nil];
                NSFileHandle *outA = [NSFileHandle fileHandleForWritingAtPath:pathA];
                YTBFetchSegments(job, a, 0, outA, step, ^(NSError *errorA) {
                    [outA closeFile];
                    if (errorA) { done(nil, nil, 0, errorA); return; }
                    if (!b.count) {
                        done(job.audioOnly ? nil : pathA, job.audioOnly ? pathA : nil, choice.height, nil);
                        return;
                    }
                    [[NSFileManager defaultManager] createFileAtPath:pathB contents:nil attributes:nil];
                    NSFileHandle *outB = [NSFileHandle fileHandleForWritingAtPath:pathB];
                    YTBFetchSegments(job, b, 0, outB, step, ^(NSError *errorB) {
                        [outB closeFile];
                        done(errorB ? nil : pathA, errorB ? nil : pathB, choice.height, errorB);
                    });
                });
            };
            if (!second) { withSecond(nil); return; }
            YTBFetchText(second, ^(NSString *secondText, NSError *error2) {
                if (error2) { done(nil, nil, 0, error2); return; }
                withSecond(secondText);
            });
        });
    });
}

// --- Assemblage, conversion et enregistrement ------------------------------------------------------

static NSError *YTBExportError(AVAssetExportSession *export, NSString *what) {
    NSError *e = export.error;
    NSError *under = e.userInfo[NSUnderlyingErrorKey];
    NSString *detail = e ? [NSString stringWithFormat:@"%@ (%ld%@)", e.localizedDescription, (long)e.code,
                            under ? [NSString stringWithFormat:@", %ld", (long)under.code] : @""] : @"raison inconnue";
    return YTBError(11, [NSString stringWithFormat:@"%@ : %@", what, detail]);
}

// Vidéo seule (piste vidéo + son éventuel) + fichier audio séparé éventuel -> .mp4
static void YTBMerge(NSString *videoPath, NSString *audioPath, NSString *outPath, void (^done)(NSError *)) {
    AVURLAsset *videoAsset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:videoPath] options:nil];
    AVAssetTrack *videoTrack = [[videoAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    AVURLAsset *audioAsset = audioPath ? [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:audioPath] options:nil] : videoAsset;
    AVAssetTrack *audioTrack = [[audioAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!videoTrack) { done(YTBError(1, @"Fichier vidéo illisible.")); return; }
    AVMutableComposition *composition = [AVMutableComposition composition];
    CMTime duration = audioTrack ? CMTimeMinimum(videoAsset.duration, audioAsset.duration) : videoAsset.duration;
    NSError *error = nil;
    AVMutableCompositionTrack *v = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    [v insertTimeRange:CMTimeRangeMake(kCMTimeZero, duration) ofTrack:videoTrack atTime:kCMTimeZero error:&error];
    v.preferredTransform = videoTrack.preferredTransform;
    if (audioTrack && !error) {
        AVMutableCompositionTrack *a = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
        [a insertTimeRange:CMTimeRangeMake(kCMTimeZero, duration) ofTrack:audioTrack atTime:kCMTimeZero error:&error];
    }
    if (error) { done(error); return; }
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetPassthrough];
    export.outputURL = [NSURL fileURLWithPath:outPath];
    export.outputFileType = AVFileTypeMPEG4;
    export.shouldOptimizeForNetworkUse = YES;
    [export exportAsynchronouslyWithCompletionHandler:^{
        done(export.status == AVAssetExportSessionStatusCompleted ? nil : YTBExportError(export, @"Assemblage impossible"));
    }];
}

// Piste audio (MP4 fragmenté) -> .m4a
static void YTBExportAudio(NSString *inPath, NSString *outPath, void (^done)(NSError *)) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:inPath] options:nil];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetAppleM4A];
    export.outputURL = [NSURL fileURLWithPath:outPath];
    export.outputFileType = AVFileTypeAppleM4A;
    [export exportAsynchronouslyWithCompletionHandler:^{
        done(export.status == AVAssetExportSessionStatusCompleted ? nil : YTBExportError(export, @"Conversion audio impossible"));
    }];
}

static void YTBSaveVideoToPhotos(NSString *path, void (^done)(NSError *)) {
    void (^save)(void) = ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:path]];
        } completionHandler:^(BOOL success, NSError *error) {
            done(success ? nil : (error ?: YTBError(3, @"Enregistrement refusé par Photos.")));
        }];
    };
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
        if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) save();
        else done(YTBError(4, @"Accès à Photos refusé. Autorisez-le dans Réglages > YouThibz > Photos."));
    }];
}

// Fichiers > Sur mon iPhone > YouThibz (dossier Documents de l'app, partagé via l'Info.plist).
static NSString *YTBDocumentsPath(NSString *name, NSString *extension) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [docs stringByAppendingPathComponent:[name stringByAppendingPathExtension:extension]];
    for (int i = 2; [[NSFileManager defaultManager] fileExistsAtPath:path]; i++)
        path = [docs stringByAppendingPathComponent:[[NSString stringWithFormat:@"%@ (%d)", name, i] stringByAppendingPathExtension:extension]];
    return path;
}

// --- Déroulé d'un téléchargement ------------------------------------------------------------------

static void YTBFinishJob(YTBJob *job, NSError *error, NSString *success) {
    [[YTBCenter shared] remove:job];
    if (error.code == -999) [[YTBCenter shared] toast:[NSString stringWithFormat:@"Téléchargement annulé : « %@ »", job.title]];
    else if (error) YTBAlert(@"Échec du téléchargement", [NSString stringWithFormat:@"« %@ »\n\n%@", job.title, error.localizedDescription]);
    else [[YTBCenter shared] toast:success];
}

// Fichiers téléchargés (vidéo et/ou audio) -> Photos ou Fichiers.
static void YTBDeliver(YTBJob *job, NSString *videoPath, NSString *audioPath, NSInteger height) {
    job.phase = @"Assemblage";
    job.progress = 0.97;
    [[YTBCenter shared] refresh];
    if (job.audioOnly) {
        NSString *out = YTBDocumentsPath(job.title, @"m4a");
        YTBExportAudio(audioPath ?: videoPath, out, ^(NSError *error) {
            YTBFinishJob(job, error, [NSString stringWithFormat:@"🎵 « %@ » enregistré dans Fichiers > Sur mon iPhone > YouThibz", job.title]);
        });
        return;
    }
    NSString *out = [job.directory stringByAppendingPathComponent:[job.title stringByAppendingPathExtension:@"mp4"]];
    YTBMerge(videoPath, audioPath, out, ^(NSError *error) {
        if (error) { YTBFinishJob(job, error, nil); return; }
        YTBSaveVideoToPhotos(out, ^(NSError *saveError) {
            YTBFinishJob(job, saveError, [NSString stringWithFormat:@"🎬 « %@ »%@ enregistrée dans Photos", job.title,
                height > 0 ? [NSString stringWithFormat:@" (%ldp)", (long)height] : @""]);
        });
    });
}

// Téléchargement à partir de liens directs (réponse de l'app ou InnerTube).
static BOOL YTBRunDirect(YTBJob *job, NSArray <YTBFormat *> *formats, NSInteger cap) {
    YTBFormat *audio = YTBBestAudio(formats);
    YTBFormat *video = job.audioOnly ? nil : YTBBestVideo(formats, cap);
    YTBFormat *muxed = (!job.audioOnly && (!video || !audio)) ? YTBBestMuxed(formats) : nil;
    if (job.audioOnly ? !audio : (!muxed && (!video || !audio))) return NO;
    YTBFormat *first = job.audioOnly ? audio : (muxed ?: video);
    YTBFormat *second = (job.audioOnly || muxed) ? nil : audio;
    NSString *pathA = [job.directory stringByAppendingPathComponent:@"a.mp4"];
    NSString *pathB = [job.directory stringByAppendingPathComponent:@"b.mp4"];
    long long total = MAX(first.length + second.length, 1);
    job.phase = job.audioOnly ? @"Audio" : @"Vidéo";
    YTBFetchFormat(job, first, pathA, ^(double f) {
        job.progress = f * first.length / total * 0.95;
        [[YTBCenter shared] refresh];
    }, ^(NSError *error) {
        if (error) { YTBFinishJob(job, error, nil); return; }
        if (!second) {
            YTBDeliver(job, job.audioOnly ? nil : pathA, job.audioOnly ? pathA : nil, first.height);
            return;
        }
        YTBFetchFormat(job, second, pathB, ^(double f) {
            job.progress = (first.length + f * second.length) / total * 0.95;
            [[YTBCenter shared] refresh];
        }, ^(NSError *error2) {
            if (error2) { YTBFinishJob(job, error2, nil); return; }
            YTBDeliver(job, pathA, pathB, first.height);
        });
    });
    return YES;
}

static void YTBStartDownload(YTPlayerViewController *player, BOOL audioOnly) {
    YTSingleVideoController *active = [player activeVideo];
    NSString *videoId = [player currentVideoID];
    if (!active || !videoId.length) { YTBAlert(@"Téléchargement", @"Aucune vidéo en cours de lecture."); return; }
    NSString *diagnostic = nil, *hls = nil;
    NSArray <YTBFormat *> *localFormats = YTBFormats(active, &diagnostic, &hls);
    NSString *title = YTBValue(YTBValue(YTBPlayerData(active), @"videoDetails"), @"title")
        ?: YTBValue(YTBValue(YTBValue([active singleVideo], @"video"), @"videoDetails"), @"title");
    NSInteger cap = YTBInt(kQualityWiFi, 1080);
    if (cap <= 0) cap = 1080;

    YTBJob *job = [YTBJob new];
    job.title = YTBSafeFileName([title isKindOfClass:NSString.class] ? title : videoId);
    job.audioOnly = audioOnly;
    job.phase = @"Préparation";
    job.backgroundTask = UIBackgroundTaskInvalid;
    job.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"YouThibz/" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:job.directory withIntermediateDirectories:YES attributes:nil error:nil];
    [[YTBCenter shared] add:job];
    [[YTBCenter shared] toast:[NSString stringWithFormat:@"⬇︎ Téléchargement lancé : « %@ »", job.title]];

    NSMutableArray <NSString *> *notes = [NSMutableArray arrayWithObject:diagnostic ?: @""];
    void (^innerTube)(void) = ^{
        job.phase = @"Recherche des liens";
        [[YTBCenter shared] refresh];
        YTBFetchInnerTube(videoId, 0, notes, ^(NSArray <YTBFormat *> *formats) {
            if (job.cancelled) { YTBFinishJob(job, YTBCancelledError(), nil); return; }
            if (!YTBRunDirect(job, formats, cap))
                YTBFinishJob(job, YTBError(5, [@"YouTube n'a pas fourni de lien téléchargeable.\n\n" stringByAppendingString:[notes componentsJoinedByString:@"\n"]]), nil);
        });
    };

    if (YTBRunDirect(job, localFormats, cap)) return;
    if (!hls) { innerTube(); return; }
    job.phase = audioOnly ? @"Audio" : @"Vidéo";
    YTBFetchHLS(job, hls, cap, ^(NSString *videoPath, NSString *audioPath, NSInteger height, NSError *error) {
        if (job.cancelled) { YTBFinishJob(job, YTBCancelledError(), nil); return; }
        if (error) {
            [notes addObject:[NSString stringWithFormat:@"HLS de l'app : %@", error.localizedDescription]];
            innerTube();
            return;
        }
        YTBDeliver(job, videoPath, audioPath, height);
    });
}

static void YTBPresentMenu(UIResponder *from, UIView *sourceView) {
    YTPlayerViewController *player = YTBPlayerFrom(from);
    if (![player activeVideo]) { YTBAlert(@"Téléchargement", @"Aucune vidéo en cours de lecture."); return; }
    NSInteger cap = YTBInt(kQualityWiFi, 1080);
    if (cap <= 0) cap = 1080;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Télécharger" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Vidéo (jusqu'à %ldp) → Photos", (long)cap] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        YTBStartDownload(player, NO);
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Audio seul → Fichiers" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        YTBStartDownload(player, YES);
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = sourceView;
    menu.popoverPresentationController.sourceRect = sourceView.bounds;
    [YTBTopController() presentViewController:menu animated:YES completion:nil];
}

static UIImage *YTBDownloadImage(void) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
    return [[UIImage systemImageNamed:@"arrow.down.circle" withConfiguration:config] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
}

// --- Bouton dans le lecteur -------------------------------------------------------------------------

%group Player
%hook YTPlayerViewController
- (void)playbackController:(id)controller didActivateVideo:(id)video withPlaybackData:(id)data {
    %orig;
    if ([self.view.superview isKindOfClass:NSClassFromString(@"YTWatchView")] || !YTBLastPlayer) YTBLastPlayer = self;
}
%end
%end

%group Top
%hook YTMainAppControlsOverlayView
- (UIImage *)buttonImage:(NSString *)tweakId {
    return [tweakId isEqualToString:kDownloadButton] ? YTBDownloadImage() : %orig;
}
%new(v@:@)
- (void)didPressYouThibzDownload:(id)arg {
    YTBPresentMenu(self, self.overlayButtons[kDownloadButton] ?: self);
}
%end
%end

%group Bottom
%hook YTInlinePlayerBarContainerView
- (UIImage *)buttonImage:(NSString *)tweakId {
    return [tweakId isEqualToString:kDownloadButton] ? YTBDownloadImage() : %orig;
}
%new(v@:@)
- (void)didPressYouThibzDownload:(id)arg {
    YTBPresentMenu(self, self.overlayButtons[kDownloadButton] ?: self);
}
%end
%end

%ctor {
    // Bouton affiché par défaut ; masquable dans Réglages > YouThibz.
    // YouQuality n'a pas de valeur par défaut chez YTVideoOverlay : on l'affiche aussi par défaut.
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kDownloadEnabled: @YES,
        @"YTVideoOverlay-YouQuality-Enabled": @YES,
    }];
    %init(Player);
    // YTVideoOverlay ajoute -buttonImage: : il doit être chargé avant nos hooks.
    NSString *overlay = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Frameworks/YTVideoOverlay.dylib"];
    if (!dlopen(overlay.fileSystemRepresentation, RTLD_LAZY)) {
        NSLog(@"[YouThibz] YTVideoOverlay introuvable : pas de bouton de téléchargement (%s)", dlerror());
        return;
    }
    [NSClassFromString(@"YTSettingsSectionItemManager") registerTweak:kDownloadButton metadata:@{
        @"accessibilityLabel": @"Télécharger",
        @"selector": @"didPressYouThibzDownload:",
        @"toggle": kDownloadEnabled,
    }];
    %init(Top);
    %init(Bottom);
}

// Téléchargement de la vidéo en cours : bouton dans le lecteur (via YTVideoOverlay, comme YouPiP et YouQuality).
//  - « Vidéo » : meilleure vidéo H.264 sous le plafond de qualité + meilleur audio AAC, assemblés en .mp4
//    puis enregistrés dans Photos.
//  - « Audio seul » : piste AAC (.m4a), proposée via la feuille de partage (« Enregistrer dans Fichiers »).
// Sources des liens, dans l'ordre : 1) liens directs de la réponse reçue par l'app ; 2) flux HLS de cette
// réponse (autorisé par le compte connecté), téléchargé par AVFoundation puis converti ; 3) nouvelle demande
// à l'API InnerTube avec un autre client (YTBInnerTubeClients). En cas d'échec, le message détaille chaque essai.
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

static UIViewController *YTBTopController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) window = w;
    }
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void YTBAlert(NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [YTBTopController() presentViewController:alert animated:YES completion:nil];
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
    if (hls) *hls = [hlsURL isKindOfClass:NSString.class] && [(NSString *)hlsURL length] ? hlsURL : nil;
    NSMutableArray *streams = [NSMutableArray array];
    for (NSString *key in @[@"adaptiveFormatsArray", @"formatsArray"]) {
        id list = YTBValue(streaming, key);
        if ([list isKindOfClass:NSArray.class]) [streams addObjectsFromArray:list];
    }
    NSUInteger withURL = 0;
    for (id stream in streams) {
        YTBFormat *f = YTBFormatFromStream(stream);
        if (f.url.length) { withURL++; [formats addObject:f]; }
    }
    // Repli : formats vidéo connus du lecteur.
    if (!formats.count) {
        for (MLFormat *format in [active selectableVideoFormats]) {
            YTBFormat *f = YTBFormatFromStream([format formatStream]);
            if (!f.url.length) f.url = [[format URL] absoluteString];
            if (!f.height) f.height = [format singleDimensionResolution];
            if (!f.mime.length) f.mime = [[format MIMEType] description] ?: @"";
            if (f.url.length) [formats addObject:f];
        }
    }
    if (diagnostic) {
        id sabr = YTBValue(streaming, @"serverAbrStreamingURL");
        *diagnostic = [NSString stringWithFormat:@"App : réponse %@, %lu formats dont %lu avec lien, HLS %@, SABR %@. Lecteur : %lu formats.",
            YTBPlayerData(active) ? @"trouvée" : @"introuvable",
            (unsigned long)streams.count, (unsigned long)withURL,
            [hlsURL isKindOfClass:NSString.class] && [(NSString *)hlsURL length] ? @"oui" : @"non",
            [sabr isKindOfClass:NSString.class] && [(NSString *)sabr length] ? @"oui" : @"non",
            (unsigned long)[[active selectableVideoFormats] count]];
    }
    return formats;
}

// --- Liens directs via l'API InnerTube -----------------------------------------------------------
// L'app lit en « SABR » (flux sans lien téléchargeable). On redemande donc la vidéo à YouTube en se
// présentant comme un autre client, qui reçoit des liens directs sans jeton. Clients et paramètres
// repris de yt-dlp (yt_dlp/extractor/youtube/_base.py, client par défaut sans JavaScript : visionos).
// Vérifiable avec le workflow « Sonde téléchargement YouTube » (scripts/yt_probe.py).

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

static NSURLSession *YTBSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 60;
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
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

// Essaie chaque client jusqu'à obtenir des liens. done(formats, titre, diagnostic) sur la file principale.
static void YTBFetchInnerTube(NSString *videoId, NSUInteger index, NSMutableArray <NSString *> *notes,
                              void (^done)(NSArray <YTBFormat *> *, NSString *, NSString *)) {
    NSArray <NSDictionary *> *clients = YTBInnerTubeClients();
    if (index >= clients.count) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(@[], nil, [notes componentsJoinedByString:@"\n"]); });
        return;
    }
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
        if (formats.count) {
            NSDictionary *details = [json[@"videoDetails"] isKindOfClass:NSDictionary.class] ? json[@"videoDetails"] : nil;
            NSString *title = [details[@"title"] isKindOfClass:NSString.class] ? details[@"title"] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{ done(formats, title, c[@"name"]); });
            return;
        }
        NSString *why = error.localizedDescription
            ?: [NSString stringWithFormat:@"%@ %@", playability[@"status"] ?: [NSString stringWithFormat:@"HTTP %ld", (long)[(NSHTTPURLResponse *)response statusCode]],
                playability[@"reason"] ?: @""];
        [notes addObject:[NSString stringWithFormat:@"%@ : %@", c[@"name"], why]];
        YTBFetchInnerTube(videoId, index + 1, notes, done);
    }] resume];
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

// --- Téléchargement par morceaux (évite le bridage de débit de YouTube) --------------------------

static const long long kChunk = 10 * 1024 * 1024;

@interface YTBDownloader : NSObject
@property (nonatomic) BOOL cancelled;
- (NSString *)userAgent;
@property (nonatomic, copy) void (^progress)(double fraction);
- (void)fetch:(YTBFormat *)format to:(NSString *)path done:(void (^)(NSError *error))done;
@end

@implementation YTBDownloader
- (NSString *)userAgent {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *ios = [UIDevice.currentDevice.systemVersion stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    return [NSString stringWithFormat:@"com.google.ios.youtube/%@ (iPhone; U; CPU iOS %@ like Mac OS X)", version, ios];
}

- (void)fetch:(YTBFormat *)format to:(NSString *)path done:(void (^)(NSError *))done {
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:path];
    [self chunkFrom:0 format:format handle:out done:^(NSError *error) {
        [out closeFile];
        done(error);
    }];
}

- (void)chunkFrom:(long long)start format:(YTBFormat *)format handle:(NSFileHandle *)out done:(void (^)(NSError *))done {
    if (self.cancelled) { done([NSError errorWithDomain:@"YouThibz" code:-999 userInfo:@{NSLocalizedDescriptionKey: @"Annulé"}]); return; }
    long long end = start + kChunk - 1;
    if (format.length > 0 && end >= format.length) end = format.length - 1;
    NSString *sep = [format.url containsString:@"?"] ? @"&" : @"?";
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@range=%lld-%lld", format.url, sep, start, end]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:format.userAgent ?: [self userAgent] forHTTPHeaderField:@"User-Agent"];
    request.timeoutInterval = 60;
    __weak typeof(self) weakSelf = self;
    [[YTBSession() dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (!error && status == 416 && start > 0) { done(nil); return; } // taille inconnue : fin du fichier atteinte
        if (error || status >= 400) {
            NSString *why = error.localizedDescription ?: [NSString stringWithFormat:@"YouTube a refusé le téléchargement (HTTP %ld).", (long)status];
            done([NSError errorWithDomain:@"YouThibz" code:status userInfo:@{NSLocalizedDescriptionKey: why}]);
            return;
        }
        [out writeData:data];
        long long next = start + data.length;
        if (format.length > 0 && weakSelf.progress) weakSelf.progress((double)next / format.length);
        BOOL finished = format.length > 0 ? next >= format.length : (long long)data.length < kChunk;
        if (finished || data.length == 0) done(nil);
        else [weakSelf chunkFrom:next format:format handle:out done:done];
    }] resume];
}
@end

// --- Téléchargement HLS (lien fourni à l'app, autorisé par son compte) ---------------------------
// AVAssetDownloadURLSession télécharge le flux HLS dans un paquet .movpkg, converti ensuite en .mp4/.m4a.

@interface YTBHLSDownloader : NSObject <AVAssetDownloadDelegate>
@property (nonatomic, strong) AVAssetDownloadURLSession *session;
@property (nonatomic, strong) AVAssetDownloadTask *task;
@property (nonatomic, strong) NSURL *location;
@property (nonatomic, copy) void (^progress)(double fraction);
@property (nonatomic, copy) void (^done)(NSURL *location, NSError *error);
- (void)download:(NSURL *)url maxHeight:(NSInteger)height userAgent:(NSString *)userAgent;
- (void)cancel;
@end

@implementation YTBHLSDownloader
- (void)download:(NSURL *)url maxHeight:(NSInteger)height userAgent:(NSString *)userAgent {
    NSString *identifier = [@"fr.famille.youthibz.hls." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:identifier];
    self.session = [AVAssetDownloadURLSession sessionWithConfiguration:config assetDownloadDelegate:self delegateQueue:NSOperationQueue.mainQueue];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{@"AVURLAssetHTTPHeaderFieldsKey": @{@"User-Agent": userAgent}}];
    NSDictionary *options = @{AVAssetDownloadTaskMinimumRequiredPresentationSizeKey: [NSValue valueWithCGSize:CGSizeMake(height * 16 / 9, height)]};
    self.task = [self.session assetDownloadTaskWithURLAsset:asset assetTitle:@"YouThibz" assetArtworkData:nil options:options];
    if (!self.task) {
        void (^done)(NSURL *, NSError *) = self.done;
        self.done = nil;
        if (done) done(nil, [NSError errorWithDomain:@"YouThibz" code:6 userInfo:@{NSLocalizedDescriptionKey: @"téléchargement HLS impossible à lancer"}]);
        return;
    }
    [self.task resume];
}
- (void)cancel { [self.task cancel]; }
- (void)URLSession:(NSURLSession *)session assetDownloadTask:(AVAssetDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    self.location = location;
}
- (void)URLSession:(NSURLSession *)session assetDownloadTask:(AVAssetDownloadTask *)task didLoadTimeRange:(CMTimeRange)timeRange
    totalTimeRangesLoaded:(NSArray <NSValue *> *)loaded timeRangeExpectedToLoad:(CMTimeRange)expected {
    double seconds = 0;
    for (NSValue *value in loaded) seconds += CMTimeGetSeconds(value.CMTimeRangeValue.duration);
    double total = CMTimeGetSeconds(expected.duration);
    if (total > 0 && self.progress) self.progress(MIN(seconds / total, 1));
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    void (^done)(NSURL *, NSError *) = self.done;
    self.done = nil;
    [session finishTasksAndInvalidate];
    if (done) done(error ? nil : self.location, error);
}
@end

static void YTBExportAsset(NSURL *source, NSString *outPath, BOOL audioOnly, void (^done)(NSError *)) {
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:source options:nil];
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:asset
        presetName:audioOnly ? AVAssetExportPresetAppleM4A : AVAssetExportPresetPassthrough];
    if (!export) { done([NSError errorWithDomain:@"YouThibz" code:7 userInfo:@{NSLocalizedDescriptionKey: @"Conversion impossible."}]); return; }
    export.outputURL = [NSURL fileURLWithPath:outPath];
    export.outputFileType = audioOnly ? AVFileTypeAppleM4A : AVFileTypeMPEG4;
    [export exportAsynchronouslyWithCompletionHandler:^{
        done(export.status == AVAssetExportSessionStatusCompleted ? nil
             : (export.error ?: [NSError errorWithDomain:@"YouThibz" code:8 userInfo:@{NSLocalizedDescriptionKey: @"Conversion échouée."}]));
    }];
}

// --- Assemblage et enregistrement ---------------------------------------------------------------

static void YTBMerge(NSString *videoPath, NSString *audioPath, NSString *outPath, void (^done)(NSError *)) {
    AVURLAsset *videoAsset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:videoPath] options:nil];
    AVURLAsset *audioAsset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:audioPath] options:nil];
    AVAssetTrack *videoTrack = [[videoAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    AVAssetTrack *audioTrack = [[audioAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (!videoTrack || !audioTrack) {
        done([NSError errorWithDomain:@"YouThibz" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Fichiers téléchargés illisibles."}]);
        return;
    }
    AVMutableComposition *composition = [AVMutableComposition composition];
    CMTime duration = CMTimeMinimum(videoAsset.duration, audioAsset.duration);
    NSError *error = nil;
    AVMutableCompositionTrack *v = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    [v insertTimeRange:CMTimeRangeMake(kCMTimeZero, duration) ofTrack:videoTrack atTime:kCMTimeZero error:&error];
    v.preferredTransform = videoTrack.preferredTransform;
    AVMutableCompositionTrack *a = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    if (!error) [a insertTimeRange:CMTimeRangeMake(kCMTimeZero, duration) ofTrack:audioTrack atTime:kCMTimeZero error:&error];
    if (error) { done(error); return; }
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetPassthrough];
    export.outputURL = [NSURL fileURLWithPath:outPath];
    export.outputFileType = AVFileTypeMPEG4;
    [export exportAsynchronouslyWithCompletionHandler:^{
        done(export.status == AVAssetExportSessionStatusCompleted ? nil
             : (export.error ?: [NSError errorWithDomain:@"YouThibz" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Assemblage impossible."}]));
    }];
}

static void YTBSaveVideoToPhotos(NSString *path, void (^done)(NSError *)) {
    void (^save)(void) = ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:path]];
        } completionHandler:^(BOOL success, NSError *error) {
            done(success ? nil : (error ?: [NSError errorWithDomain:@"YouThibz" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Enregistrement refusé."}]));
        }];
    };
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
        if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) save();
        else done([NSError errorWithDomain:@"YouThibz" code:4 userInfo:@{NSLocalizedDescriptionKey:
            @"Accès à Photos refusé. Autorisez-le dans Réglages > YouThibz > Photos."}]);
    }];
}

static void YTBShareFile(NSString *path, UIView *sourceView) {
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
    share.popoverPresentationController.sourceView = sourceView;
    share.popoverPresentationController.sourceRect = sourceView.bounds;
    [YTBTopController() presentViewController:share animated:YES completion:nil];
}

// --- Déroulé d'un téléchargement ------------------------------------------------------------------

static void YTBRun(YTPlayerViewController *player, BOOL audioOnly, UIView *sourceView) {
    YTSingleVideoController *active = [player activeVideo];
    NSString *videoId = [player currentVideoID];
    if (!videoId.length) { YTBAlert(@"Téléchargement", @"Vidéo introuvable."); return; }
    NSString *localDiagnostic = nil, *hls = nil;
    NSArray <YTBFormat *> *localFormats = YTBFormats(active, &localDiagnostic, &hls);
    id details = YTBValue(YTBValue([active singleVideo], @"video"), @"videoDetails");
    NSString *localTitle = YTBValue(details, @"title");

    YTBDownloader *downloader = [YTBDownloader new];
    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Téléchargement" message:@"Recherche des liens…" preferredStyle:UIAlertControllerStyleAlert];
    __block YTBHLSDownloader *hlsJob = nil;
    [progress addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        downloader.cancelled = YES;
        [hlsJob cancel];
    }]];
    [YTBTopController() presentViewController:progress animated:YES completion:nil];

    __block UIBackgroundTaskIdentifier task = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
        downloader.cancelled = YES;
    }];
    void (^finishWith)(NSError *, NSString *, NSString *, NSString *) = ^(NSError *error, NSString *errorTitle, NSString *okTitle, NSString *okMessage) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [progress dismissViewControllerAnimated:YES completion:^{
                if (error && error.code != -999) YTBAlert(errorTitle ?: @"Échec du téléchargement", error.localizedDescription);
                else if (!error && okTitle) YTBAlert(okTitle, okMessage);
            }];
            [UIApplication.sharedApplication endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        });
    };
    void (^finish)(NSError *, NSString *, NSString *) = ^(NSError *error, NSString *okTitle, NSString *okMessage) {
        finishWith(error, nil, okTitle, okMessage);
    };
    void (^status)(NSString *) = ^(NSString *text) {
        dispatch_async(dispatch_get_main_queue(), ^{ progress.message = text; });
    };

    NSMutableArray <NSString *> *notes = [NSMutableArray array];
    void (^proceed)(NSArray <YTBFormat *> *, NSString *, NSString *) = ^(NSArray <YTBFormat *> *remoteFormats, NSString *remoteTitle, NSString *remoteNote) {
        if (downloader.cancelled) { finish([NSError errorWithDomain:@"YouThibz" code:-999 userInfo:nil], nil, nil); return; }
        NSArray <YTBFormat *> *formats = remoteFormats.count ? remoteFormats : localFormats;
        NSInteger cap = YTBInt(kQualityWiFi, 1080);
        if (cap <= 0) cap = 1080;

        YTBFormat *audio = YTBBestAudio(formats);
        YTBFormat *video = audioOnly ? nil : YTBBestVideo(formats, cap);
        YTBFormat *muxed = nil;
        if (!audioOnly && (!video || !audio)) muxed = YTBBestMuxed(formats); // repli : format tout-en-un (souvent 360p)
        if ((audioOnly && !audio) || (!audioOnly && !muxed && (!video || !audio))) {
            NSString *message = [NSString stringWithFormat:@"YouTube n'a pas fourni de lien téléchargeable pour cette vidéo.\n\n%@\n%@",
                remoteFormats.count ? [NSString stringWithFormat:@"%@ : %lu formats, aucun utilisable.", remoteNote, (unsigned long)remoteFormats.count]
                    : [notes componentsJoinedByString:@"\n"],
                localDiagnostic];
            finishWith([NSError errorWithDomain:@"YouThibz" code:5 userInfo:@{NSLocalizedDescriptionKey: message}], @"Téléchargement impossible", nil, nil);
            return;
        }

        NSString *title = YTBSafeFileName(remoteTitle ?: localTitle ?: videoId);
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"YouThibz/" stringByAppendingString:videoId]];
        [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

        if (audioOnly) {
            NSString *path = [dir stringByAppendingPathComponent:[title stringByAppendingPathExtension:@"m4a"]];
            downloader.progress = ^(double f) { status([NSString stringWithFormat:@"Audio : %d %%", (int)(f * 100)]); };
            [downloader fetch:audio to:path done:^(NSError *error) {
                if (error) { finish(error, nil, nil); return; }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [progress dismissViewControllerAnimated:YES completion:^{ YTBShareFile(path, sourceView); }];
                    [UIApplication.sharedApplication endBackgroundTask:task];
                });
            }];
            return;
        }

        NSString *output = [dir stringByAppendingPathComponent:[title stringByAppendingPathExtension:@"mp4"]];
        NSString *label = [NSString stringWithFormat:@"%ldp", (long)(muxed ?: video).height];
        void (^save)(void) = ^{
            status(@"Enregistrement dans Photos…");
            YTBSaveVideoToPhotos(output, ^(NSError *error) {
                [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
                finish(error, @"Vidéo enregistrée", [NSString stringWithFormat:@"« %@ » (%@) est dans l'app Photos.", title, label]);
            });
        };
        if (muxed) {
            downloader.progress = ^(double f) { status([NSString stringWithFormat:@"Vidéo %@ : %d %%", label, (int)(f * 100)]); };
            [downloader fetch:muxed to:output done:^(NSError *error) { if (error) finish(error, nil, nil); else save(); }];
            return;
        }
        NSString *videoPath = [dir stringByAppendingPathComponent:@"video.mp4"];
        NSString *audioPath = [dir stringByAppendingPathComponent:@"audio.m4a"];
        downloader.progress = ^(double f) { status([NSString stringWithFormat:@"Vidéo %@ : %d %%", label, (int)(f * 100)]); };
        [downloader fetch:video to:videoPath done:^(NSError *error) {
            if (error) { finish(error, nil, nil); return; }
            downloader.progress = ^(double f) { status([NSString stringWithFormat:@"Audio : %d %%", (int)(f * 100)]); };
            [downloader fetch:audio to:audioPath done:^(NSError *error) {
                if (error) { finish(error, nil, nil); return; }
                status(@"Assemblage…");
                YTBMerge(videoPath, audioPath, output, ^(NSError *error) {
                    if (error) finish(error, nil, nil);
                    else save();
                });
            }];
        }];
    };

    void (^innerTube)(void) = ^{
        status(@"Recherche des liens…");
        YTBFetchInnerTube(videoId, 0, notes, proceed);
    };

    NSInteger cap = YTBInt(kQualityWiFi, 1080);
    if (cap <= 0) cap = 1080;
    BOOL localUsable = audioOnly ? YTBBestAudio(localFormats) != nil
        : ((YTBBestVideo(localFormats, cap) && YTBBestAudio(localFormats)) || YTBBestMuxed(localFormats));
    if (localUsable) { proceed(@[], nil, @"app"); return; }
    if (!hls) { innerTube(); return; }

    // Flux HLS fourni à l'app : vidéo et son déjà réunis.
    NSString *title = YTBSafeFileName(localTitle ?: videoId);
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"YouThibz/" stringByAppendingString:videoId]];
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    status(@"Téléchargement…");
    hlsJob = [YTBHLSDownloader new];
    hlsJob.progress = ^(double f) { status([NSString stringWithFormat:@"%@ : %d %%", audioOnly ? @"Audio" : @"Vidéo", (int)(f * 100)]); };
    hlsJob.done = ^(NSURL *location, NSError *error) {
        if (downloader.cancelled) { finish([NSError errorWithDomain:@"YouThibz" code:-999 userInfo:nil], nil, nil); return; }
        if (!location) {
            [notes addObject:[NSString stringWithFormat:@"HLS de l'app : %@", error.localizedDescription ?: @"aucun fichier reçu"]];
            innerTube();
            return;
        }
        status(@"Conversion…");
        NSString *output = [dir stringByAppendingPathComponent:[title stringByAppendingPathExtension:audioOnly ? @"m4a" : @"mp4"]];
        YTBExportAsset(location, output, audioOnly, ^(NSError *exportError) {
            [[NSFileManager defaultManager] removeItemAtURL:location error:nil];
            if (exportError) { finish(exportError, nil, nil); return; }
            if (audioOnly) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [progress dismissViewControllerAnimated:YES completion:^{ YTBShareFile(output, sourceView); }];
                    [UIApplication.sharedApplication endBackgroundTask:task];
                });
                return;
            }
            status(@"Enregistrement dans Photos…");
            YTBSaveVideoToPhotos(output, ^(NSError *saveError) {
                [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
                finish(saveError, @"Vidéo enregistrée", [NSString stringWithFormat:@"« %@ » est dans l'app Photos.", title]);
            });
        });
    };
    [hlsJob download:[NSURL URLWithString:hls] maxHeight:cap userAgent:[downloader userAgent]];
}

static void YTBPresentMenu(UIResponder *from, UIView *sourceView) {
    YTPlayerViewController *player = YTBPlayerFrom(from);
    if (![player activeVideo]) { YTBAlert(@"Téléchargement", @"Aucune vidéo en cours de lecture."); return; }
    NSInteger cap = YTBInt(kQualityWiFi, 1080);
    if (cap <= 0) cap = 1080;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Télécharger" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Vidéo (jusqu'à %ldp) → Photos", (long)cap] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        YTBRun(player, NO, sourceView);
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Audio seul → Fichiers" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        YTBRun(player, YES, sourceView);
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

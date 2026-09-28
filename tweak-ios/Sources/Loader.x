// Charge les briques open source au démarrage, sauf celles désactivées dans les réglages.
// Le build retire leur chargement automatique du binaire de YouTube (scripts/strip_load_commands.py) :
// sans YouThibz, elles resteraient inactives.
#import "Modules.h"
#import <dlfcn.h>

%ctor {
    NSString *frameworks = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Frameworks"];
    for (NSArray <NSString *> *module in YTBModules()) {
        NSString *name = module[0];
        if (!YTBBool(YTBModuleKey(name), YES)) {
            NSLog(@"[YouThibz] brique désactivée : %@", name);
            continue;
        }
        NSString *path = [frameworks stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"dylib"]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        if (!dlopen(path.fileSystemRepresentation, RTLD_NOW))
            NSLog(@"[YouThibz] échec du chargement de %@ : %s", name, dlerror());
    }
}

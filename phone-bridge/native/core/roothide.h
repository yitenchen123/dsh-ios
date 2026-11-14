#ifndef DSH_ROOTHIDE_STUB_H
#define DSH_ROOTHIDE_STUB_H
#import <Foundation/Foundation.h>
static inline NSString *jbroot(NSString *path) {
    if (![path isKindOfClass:[NSString class]] || path.length == 0) return path;
    if ([path hasPrefix:@"/var/jb"]) return path;
    return [@"/var/jb" stringByAppendingString:path];
}
static inline NSString *rootfs(NSString *path) { return path; }
#endif

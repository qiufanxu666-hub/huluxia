#import <Foundation/Foundation.h>

// Deliberately non-invasive scaffold: only activates for Bundle IDs compiled
// into the tweak's filter. Add feature hooks only for apps you own or are
// explicitly authorized to test.
__attribute__((constructor)) static void HXInitialize(void) {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
        NSLog(@"[HuluXia] loaded in allowlisted process: %@", bundleID);
    }
}

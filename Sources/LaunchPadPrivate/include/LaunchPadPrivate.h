// Private system interfaces used by the Launchpad model, as the original uses them.
// Verified on macOS 27.0.1 (26A434) and macOS 26.6.2 (25G83).

#ifndef LAUNCHPAD_PRIVATE_H
#define LAUNCHPAD_PRIVATE_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

CF_ASSUME_NONNULL_BEGIN

// LaunchServices version numbers (CFBundleVersion parsed and compared the way
// LaunchServices does). Used for an app's version and to choose between two
// copies of an app (REF-LAYOUT-003).
typedef struct LSVersionNumber {
    unsigned char _opaque[32];
} LSVersionNumber;

extern const LSVersionNumber kLSVersionNumberNull;
extern LSVersionNumber _LSGetVersionFromString(CFStringRef string);
extern CFComparisonResult _LSVersionNumberCompare(LSVersionNumber a, LSVersionNumber b);

// URL resource keys and Info.plist keys that have no public name.
extern const CFStringRef _kCFURLApplicationHasSupportedFormatKey;
extern const CFStringRef _kCFURLApplicationCategoriesKey;
extern const CFStringRef _kCFURLApplicationIsBetaKey;
extern const CFStringRef _kCFURLApplicationSupportedRegionsKey;
extern const CFStringRef _kCFBundleIconFileKey;

// The system build version written into a new database (REF-LAYOUT-002).
extern CFDictionaryRef _Nullable _CFCopySystemVersionDictionary(void);
extern const CFStringRef _kCFSystemVersionBuildVersionKey;

// Gates the ResetLaunchPad preference (REF-LAYOUT-001).
extern bool os_variant_allows_internal_security_policies(const char *subsystem);

#ifdef __OBJC__
// LaunchServices' record of an installed app; public on iOS, not declared on macOS.
// Tells whether a scanned app is a web app (flag 0x1000, REF-LAYOUT-003).
@interface LSApplicationRecord : NSObject
- (nullable instancetype)initWithURL:(NSURL *)url
                    allowPlaceholder:(BOOL)allowPlaceholder
                               error:(NSError **)error;
@property (readonly) BOOL isWebApp;
@end
#endif

CF_ASSUME_NONNULL_END

#endif

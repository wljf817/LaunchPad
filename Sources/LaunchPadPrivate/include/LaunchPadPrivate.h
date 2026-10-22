// Private system interfaces used as the original uses them.
// Verified on macOS 27.0.1 (26A434) and macOS 26.6.2 (25G83) unless noted.

#ifndef LAUNCHPAD_PRIVATE_H
#define LAUNCHPAD_PRIVATE_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>
#include <stdbool.h>
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
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

// ---------------------------------------------------------------------------
// Window server, process manager and Dock interfaces the original calls while
// opening and closing (springboard-shell). Verified on macOS 26.6.2 (25G83)
// and macOS 27.0.1 (26A434) unless noted.

typedef int32_t CGSConnectionID;
typedef uint32_t CGSWindowID;

// The process's own window-server connection (the original uses Dock's).
extern CGSConnectionID CGSMainConnectionID(void);

// Window level, tags and properties of the app's own windows (REF-ARCH-008,
// REF-OVERLAY-006). Tags verified on 26.6.2 and 27.0.1 in the 6.1 spike.
extern CGError CGSSetWindowLevel(CGSConnectionID cid, CGSWindowID wid, int32_t level);
extern CGError CGSSetWindowTags(CGSConnectionID cid, CGSWindowID wid, const uint64_t *tags, int32_t tagSize);
extern CGError CGSSetWindowProperty(CGSConnectionID cid, CGSWindowID wid, CFStringRef key, CFTypeRef value);

// The original orders its window in a SkyLight transaction (-[Springboard
// orderWindowOn:]) and animates the safe-aperture override through one
// (REF-DEV-011: ignored by the window server for a process that is not Dock).
extern CFTypeRef _Nullable SLSTransactionCreate(CGSConnectionID cid) CF_RETURNS_RETAINED;
extern CGError SLSTransactionCommit(CFTypeRef transaction, int32_t synchronous);
extern void SLSTransactionSetSafeApertureOverride(CFTypeRef transaction, double value);

// Called by the original at open and close; an empty function in SkyLight on
// 15.6.1 and 26.6.2.
extern CGError CGSSetDisplayAcceleratorBoost(CGDirectDisplayID display, int32_t boost);

// Cursor 0 is the arrow (REF-DEV-006). CoreCursorSet takes effect for a process
// that is not frontmost only with the connection property
// "SetsCursorInBackground" set (26.6.2).
extern CGError CGSSetConnectionProperty(CGSConnectionID cid, CGSConnectionID target, CFStringRef key, CFTypeRef value);
extern CGError CoreCursorSet(CGSConnectionID cid, int32_t cursor);

// The live state of a modifier key (1: Shift), as +[ECModalEventController
// shiftKeyDown] reads it.
extern bool CGSInputModifierKeyState(int32_t unknown, int32_t key);

// Captures windows of the window server; the background is a capture of the
// wallpaper window (REF-OVERLAY-003, REF-DEV-015). Needs no permission.
extern CFArrayRef _Nullable CGSHWCaptureWindowList(CGSConnectionID cid, CGSWindowID *wids, int32_t count, uint32_t options) CF_RETURNS_RETAINED;

// Spaces: whether a display is animating a space switch (REF-DEV-007), the
// active space and the managed displays' spaces (REF-DEV-015). 26.6.2 only.
extern bool CGSManagedDisplayIsAnimating(CGSConnectionID cid, CFStringRef displayUUID);
extern uint64_t CGSGetActiveSpace(CGSConnectionID cid);
extern CFArrayRef _Nullable CGSCopyManagedDisplaySpaces(CGSConnectionID cid) CF_RETURNS_RETAINED;

// Keyboard focus without activating the process (REF-OVERLAY-007).
extern CGError CPSStealKeyFocusOnConnection(CGSConnectionID cid, uint32_t flags);
extern CGError CPSReleaseKeyFocusOnConnection(CGSConnectionID cid);

// Dock: a notification to the Dock's message server (Mission Control's toggle,
// REF-DEV-005) and the auto-hide preference (REF-DEV-004). 26.6.2 only.
extern void CoreDockSendNotification(CFStringRef name, CFTypeRef _Nullable unknown);
extern Boolean CoreDockGetAutoHideEnabled(void);
extern void CoreDockSetAutoHideEnabled(Boolean enabled);

// The frontmost app's presentation options in LaunchServices, for the
// process-switching guard (REF-DEV-007). 26.6.2 only.
extern CFTypeRef _Nullable _LSCopyFrontApplication(int32_t session) CF_RETURNS_RETAINED;
extern CFTypeRef _Nullable _LSCopyApplicationInformationItem(int32_t session, CFTypeRef asn, CFStringRef key) CF_RETURNS_RETAINED;
extern const CFStringRef _kLSUIPresentationOptionsKey;

// The system's Reduce Motion setting; Dock's accessibility monitor reads this.
extern Boolean _AXInterfaceGetReduceMotionEnabled(void);

#ifdef __OBJC__
// Core Animation's private filters, used for the background (REF-OVERLAY-005).
@interface CAFilter : NSObject <NSCopying>
+ (instancetype)filterWithType:(NSString *)type;
@end

extern NSString * const kCAFilterGaussianBlur;
extern NSString * const kCAFilterColorSaturate;
extern NSString * const kCAFilterColorMatrix;

// 20 floats: one row per output component (R, G, B, A), each the coefficients of
// input R, G, B, A and a constant (REF-OVERLAY-005).
typedef struct CAColorMatrix {
    float m11, m12, m13, m14, m15;
    float m21, m22, m23, m24, m25;
    float m31, m32, m33, m34, m35;
    float m41, m42, m43, m44, m45;
} CAColorMatrix;

@interface NSValue (CAColorMatrix)
+ (NSValue *)valueWithCAColorMatrix:(CAColorMatrix)matrix;
@property (readonly) CAColorMatrix CAColorMatrixValue;
@end

// Runs a block when the current transaction commits, at the given phase
// (1: before the commit). The strip window's copy of the layer tree is brought
// up to date there (springboard-shell design decision 3).
@interface CATransaction (LaunchPadCommitHandler)
+ (void)addCommitHandler:(void (^)(void))block forPhase:(int)phase;
@end

// ---------------------------------------------------------------------------
// The grid (grid-tree). Verified on macOS 26.6.2 (25G83) and macOS 27.0.1
// (26A434).

// Group blending of a layer's sublayers. The loading indicator's container and
// an item layer's jitter layer turn it off (REF-GRID-002, research paper §6).
@interface CALayer (LaunchPadGroupBlending)
@property BOOL allowsGroupBlending;
@end

// The "plusL" compositing filter of the loading indicator's text (REF-GRID-002).
extern NSString * const kCAFilterPlusL;

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

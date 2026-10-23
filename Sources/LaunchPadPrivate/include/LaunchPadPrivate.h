// Private system interfaces used as the original uses them.
// Verified on macOS 27.0.1 (26A434) and macOS 26.6.2 (25G83) unless noted.

#ifndef LAUNCHPAD_PRIVATE_H
#define LAUNCHPAD_PRIVATE_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
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
// Orders a window and its window group in (order 1, in front of `otherWindow`, 0 for every window of
// its level) or out (order 0), when the transaction is committed. Verified on macOS 26.6.2.
extern void SLSTransactionOrderWindowGroup(CFTypeRef transaction, CGSWindowID wid, int32_t order, CGSWindowID otherWindow);
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
// The spaces a window belongs to (mask 7: every kind of space), as an array of
// space ids. The strip over the menu bar takes its height from the active
// space's menu bar window (REF-DEV-003). 27.0.1 and 26.6.2.
extern CFArrayRef _Nullable CGSCopySpacesForWindows(CGSConnectionID cid, int32_t mask, CFArrayRef wids) CF_RETURNS_RETAINED;

// Keyboard focus without activating the process (REF-OVERLAY-007).
extern CGError CPSStealKeyFocusOnConnection(CGSConnectionID cid, uint32_t flags);
extern CGError CPSReleaseKeyFocusOnConnection(CGSConnectionID cid);

// Dock: a notification to the Dock's message server (Mission Control's toggle,
// REF-DEV-005), 26.6.2 only; and the tile size (REF-DEV-004), the Dock's
// preference size as (size - 16) / 112, set with a flag that says whether the
// change is finished: while it is not, the Dock shows itself. 26.6.2 and 27.0.1.
extern void CoreDockSendNotification(CFStringRef name, CFTypeRef _Nullable unknown);
extern float CoreDockGetTileSize(void);
extern void CoreDockSetTileSize(float size, int32_t finished);

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

// Whether a layer takes part in hit testing. A folder icon's mini icon grid
// does not (REF-GRID-013).
@interface CALayer (LaunchPadHitTesting)
@property BOOL allowsHitTesting;
@end

// The "plusL" compositing filter of the loading indicator's text (REF-GRID-002).
extern NSString * const kCAFilterPlusL;

// The compositing filter of a folder icon's tint layer (REF-GRID-013).
extern NSString * const kCAFilterDarkenBlendMode;

// LaunchServices' record of an installed app; public on iOS, not declared on macOS.
// Tells whether a scanned app is a web app (flag 0x1000, REF-LAYOUT-003).
@interface LSApplicationRecord : NSObject
- (nullable instancetype)initWithURL:(NSURL *)url
                    allowPlaceholder:(BOOL)allowPlaceholder
                               error:(NSError **)error;
@property (readonly) BOOL isWebApp;
@end
#endif

// ---------------------------------------------------------------------------
// Grid geometry (grid-geometry). Verified on macOS 26.6.2 (25G83) and macOS
// 27.0.1 (26A434).

// A UI font descriptor of a type Core Text does not make public. The label font
// of the grid is type 105, 13 points (REF-GRID-006); the call gives
// .SFNS-Medium with the same metrics on 15.6.1, 26.6.2 and 27.0.1.
extern CTFontDescriptorRef _Nullable CTFontDescriptorCreateForUIType(CTFontUIFontType uiType, CGFloat size,
                                                                     CFStringRef _Nullable language) CF_RETURNS_RETAINED;

// Whether the system's user interface is right to left, when no writing
// direction is forced by preference (REF-GRID-009).
extern bool SLSGetSystemUIHasRTLDirectionLegacy(void);

// The Dock's rectangle as the window server has it (its thickness is the height
// at the bottom, the width at a side; 0 while it is hidden) and its position (2
// bottom, 3 left, 4 right). The grid's room for the Dock is converted from them
// (REF-DEV-019). HIServices' CoreDockGetRect returns the same, but keeps the
// first answer in the process and updates it only through the event loop.
extern CGError SLSGetDockRectWithOrientation(CGSConnectionID cid, CGRect *rect, int32_t *reason, int32_t *orientation);

// ---------------------------------------------------------------------------
// Icons (grid-items, REF-GRID-012). Verified on macOS 15.6.1 (24G90), 26.6.2
// (25G83) and 27.0.1 (26A434): the symbols exist with these arguments and give
// images.

// A LaunchServices binding for an app's URL, and one for a type and creator code
// (the original uses type 0 and creator 0x6e6c6464 for its placeholder icon).
extern CFTypeRef _Nullable _LSBindingCreateWithURL(CFAllocatorRef _Nullable allocator, CFURLRef url) CF_RETURNS_RETAINED;
extern CFTypeRef _Nullable _LSBindingCreateWithTypeInfo(CFAllocatorRef _Nullable allocator, uint32_t type, uint32_t creator,
                                                        CFStringRef _Nullable extension, uint64_t flags) CF_RETURNS_RETAINED;
// The binding's IconRef, the identity the sized icon cache keys on.
extern void * _Nullable _LSBindingGetIconRef(CFTypeRef binding);

// An app's icon image from IconServices, at a size in pixels and an integer scale.
extern CGImageRef _Nullable ISCreateCGImageFromBindingWithSizeScaleAndOptions(CFTypeRef binding, CGSize size, uint32_t scale,
                                                                              CFDictionaryRef _Nullable options) CF_RETURNS_RETAINED;

// Image I/O's option that skips metadata when decoding a stored icon; exported,
// not in the public headers.
extern const CFStringRef kCGImageSourceSkipMetadata;

// Drawing an icon into a bitmap: the copy compositing operation (1), and a
// reused bitmap context pointed at new memory.
extern void CGContextSetCompositeOperation(CGContextRef context, int32_t operation);
extern void CGBitmapContextSetData(CGContextRef context, size_t x, size_t y, size_t width, size_t height, void *data,
                                   size_t bitsPerComponent, size_t bitsPerPixel, size_t bytesPerRow);

// Core Animation's render image: the contents of a sized icon cache entry
// (ECSizedIconImageCacheRenderObject). Format 1 with one level over memory the
// release callback unmaps (called with the data and releaseInfo).
typedef struct _CARenderImage *CARenderImageRef;
extern CARenderImageRef _Nullable CARenderImageNewMipmapped(uint32_t format, size_t width, size_t height, uint32_t levels,
                                                            CGColorSpaceRef space, const void *data, const size_t *rowBytes,
                                                            void (*_Nullable release)(void *_Nullable, size_t),
                                                            size_t releaseInfo);
extern CGImageRef _Nullable CARenderImageCopyCGImage(CARenderImageRef image) CF_RETURNS_RETAINED;
extern size_t CARenderImageGetWidth(CARenderImageRef image);
extern size_t CARenderImageGetHeight(CARenderImageRef image);
extern void * _Nullable CARenderRetain(void *_Nullable object);
extern void CARenderRelease(void *_Nullable object);

#ifdef __OBJC__
// IconServices' Objective-C interface, used for the placeholder icon.
@interface ISImageDescriptor : NSObject
- (instancetype)initWithSize:(CGSize)size scale:(CGFloat)scale;
@property (nonatomic) NSUInteger backgroundStyle;
@end

@interface ISImage : NSObject
@property (readonly, nullable) CGImageRef CGImage;
@property (readonly) BOOL placeholder;
@end

@interface ISIcon : NSObject
- (instancetype)initWithBinding:(id)binding;
- (void)prepareImagesForImageDescriptors:(NSArray<ISImageDescriptor *> *)descriptors;
- (nullable ISImage *)imageForImageDescriptor:(ISImageDescriptor *)descriptor;
@end
#endif

CF_ASSUME_NONNULL_END

#endif

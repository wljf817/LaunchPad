// Private system interfaces the text input service uses as the original service does
// (REF-SEARCH-011). All verified on macOS 26.6.2 (25G83) in the text-input spike: the service set up
// with them showed its text field through a CALayerHost in another process and took posted keys
// (REF-DEV-034). -_setFrame: was called there without changing the window server's bounds of the
// never-ordered mini view window.

#ifndef LAUNCHPAD_ECTI_PRIVATE_H
#define LAUNCHPAD_ECTI_PRIVATE_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#ifdef __OBJC__
#import <AppKit/AppKit.h>
#endif

CF_ASSUME_NONNULL_BEGIN

// The process serial number of a process, as the process manager keeps it.
typedef struct CPSProcessSerNum {
    uint32_t hi;
    uint32_t lo;
} CPSProcessSerNum;

// The service's own process serial number, sent to the search field in the setup reply.
// Exported by CoreGraphics.
extern OSStatus _CPSGetCurrentProcess(CPSProcessSerNum *psn);

// Lets the Text Services Manager use a remote view for this process's text input, as the service
// does before it puts the text field into its mini view. Exported by HIToolbox (Carbon).
extern void _TSMSetRemoteViewActivation(Boolean activate);
extern void _TSMRegisterRemoteViewClient(Boolean client);

#ifdef __OBJC__
// AppKit's mini view of the application's Dock tile: setting it makes a borderless window holding
// the view and sends its window number and context id to the Dock (CoreDockSetMiniView); the Dock's
// notification that the mini view is shown or hidden reaches -_setMiniViewShown:.
@interface NSDockTile (LaunchPadECTIMiniView)
@property (nullable, strong) NSView *miniView;
- (void)_setMiniViewWindowLevel:(NSInteger)level;
- (void)_setMiniViewShown:(BOOL)shown;
@end

// The Core Animation context a window's layers are hosted with; its id is what CoreDockSetMiniView
// sends for the mini view.
@interface CAContext : NSObject
@property (readonly) uint32_t contextId;
@end

@interface NSWindow (LaunchPadECTIPrivate)
- (CAContext *)_contextForLayerHosting;
// Moves the window without the checks and notifications of -setFrame:display:.
- (void)_setFrame:(NSRect)frame;
@end

@interface NSTextFieldCell (LaunchPadECTIPrivate)
// The setter of the read-only wantsNotificationForMarkedText: the cell tells its control when the
// input method's marked text changes.
- (void)setWantsNotificationForMarkedText:(BOOL)flag;
@end

@interface NSScreen (LaunchPadECTIPrivate)
// The height of the screen whose origin is the global origin; flips the Dock's top-left
// coordinates into AppKit's.
+ (CGFloat)_zeroScreenHeight;
@end
#endif

CF_ASSUME_NONNULL_END

#endif

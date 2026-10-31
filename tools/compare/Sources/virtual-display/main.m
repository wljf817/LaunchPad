// Adds one virtual display, for the multi-display scenes: the VMs have a single
// display (REF-ENV-004). The display exists while this process runs and goes
// away when it ends. SIGUSR1 switches it between its mode and the alternate
// mode, which is a display reconfiguration like a resolution change. The same
// binary runs in the macOS 15 reference VM and in the macOS 26 comparison VM;
// it must run in the logged-in user's session (vm-common.sh starts it there).
//
// Private API: CoreGraphics' CGVirtualDisplay classes, the only way found to
// add a display inside the VMs. Verified on macOS 15.6.1 and 26.6.2.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <signal.h>
#include <stdio.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain) dispatch_queue_t queue;
@property(copy) NSString *name;
@property unsigned int maxPixelsHigh;
@property unsigned int maxPixelsWide;
@property CGSize sizeInMillimeters;
@property unsigned int serialNum;
@property unsigned int productID;
@property unsigned int vendorID;
@property CGPoint redPrimary;
@property CGPoint greenPrimary;
@property CGPoint bluePrimary;
@property CGPoint whitePoint;
@property(copy) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property unsigned int hiDPI;
@property(retain) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly) CGDirectDisplayID displayID;
@end

static const char *usage =
    "usage: virtual-display <width> <height> --alt <width>x<height> [--hidpi]\n"
    "Adds a display of <width> x <height> points at 60 Hz until the process ends. SIGUSR1\n"
    "switches it to the --alt size and back. --hidpi gives it twice as many pixels.\n";

static BOOL apply(CGVirtualDisplay *display, unsigned int width, unsigned int height, unsigned int hiDPI) {
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = hiDPI;
    // REF-ENV-004: 60 Hz, as the VMs' own display.
    settings.modes = @[[[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width height:height refreshRate:60]];
    return [display applySettings:settings];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        unsigned int width = 0, height = 0, altWidth = 0, altHeight = 0, hiDPI = 0;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--alt") == 0 && i + 1 < argc) {
                if (sscanf(argv[++i], "%ux%u", &altWidth, &altHeight) != 2) altWidth = 0;
            } else if (strcmp(argv[i], "--hidpi") == 0) {
                hiDPI = 1;
            } else if (width == 0) {
                width = (unsigned int)strtoul(argv[i], NULL, 10);
            } else if (height == 0) {
                height = (unsigned int)strtoul(argv[i], NULL, 10);
            } else {
                width = 0;
                break;
            }
        }
        if (width == 0 || height == 0 || altWidth == 0 || altHeight == 0) {
            fputs(usage, stderr);
            return 2;
        }
        unsigned int scale = hiDPI ? 2 : 1;
        CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        descriptor.queue = dispatch_get_main_queue();
        descriptor.name = @"LaunchPad Virtual Display";
        descriptor.maxPixelsWide = MAX(width, altWidth) * scale;
        descriptor.maxPixelsHigh = MAX(height, altHeight) * scale;
        // REF-ENV-004: the maximum image size and the chromaticity of the VMs' own display.
        descriptor.sizeInMillimeters = CGSizeMake(490, 310);
        descriptor.redPrimary = CGPointMake(0.6400, 0.3300);
        descriptor.greenPrimary = CGPointMake(0.3000, 0.6000);
        descriptor.bluePrimary = CGPointMake(0.1500, 0.0600);
        descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
        // Fixed identity, so the window server puts it back where it was last arranged.
        descriptor.vendorID = 0x4C50;
        descriptor.productID = 0x0106;
        descriptor.serialNum = 1;
        descriptor.terminationHandler = ^(id a, id b) {
            fputs("virtual-display: the display was terminated\n", stderr);
            exit(1);
        };
        CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
        if (display == nil || !apply(display, width, height, hiDPI)) {
            fputs("virtual-display: could not add the display\n", stderr);
            return 1;
        }
        printf("display %u %ux%u\n", display.displayID, width, height);
        fflush(stdout);

        signal(SIGUSR1, SIG_IGN);
        __block BOOL alternate = NO;
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(source, ^{
            alternate = !alternate;
            unsigned int w = alternate ? altWidth : width, h = alternate ? altHeight : height;
            if (!apply(display, w, h, hiDPI)) {
                fputs("virtual-display: could not switch the mode\n", stderr);
                exit(1);
            }
            printf("display %u %ux%u\n", display.displayID, w, h);
            fflush(stdout);
        });
        dispatch_resume(source);
        dispatch_main();
    }
}

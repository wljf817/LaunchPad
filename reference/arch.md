# Architecture

Where and how macOS 15 implements Launchpad: binaries, processes, classes. Class names, superclasses and adopted protocols are listed as `Class : Superclass <Protocols>`.

## REF-ARCH-001 Binary that implements Launchpad

- **Status:** measured
- **Value:**
  - `/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock` (bundle ID `com.apple.dock`, version 1.8, build 2341.6.1, x86_64 + arm64e). The Launchpad classes in REF-ARCH-002 and REF-ARCH-003 are compiled into this executable.
  - None of the 27 private frameworks Dock links exports a Launchpad-related symbol, and none of the 3,257 images split from the arm64e dyld shared cache contains the class names `ECSBSpringboard`, `LPSpringboard` or `LPStorage`.
  - Dock links QuartzCore but not AppKit or SwiftUI. Its imports from the frameworks it links are generic services, for example layers and animations (QuartzCore), icons (IconServices), app removal (`UNUninstallClient`, private Uninstall framework) and SQLite (`libsqlite3`).
- **Source:** static analysis of the binaries fetched from the reference VM with `tools/re/vm-fetch.sh`, the dyld cache split with `tools/re/dsc-extract.swift`. REA (rea-agents 6.5.0): `inspect_macho` and `inspect_native_dispatch_metadata` on Dock and DockHelper, `inspect_macho` on each private framework Dock links. `dyld_info -objc` for the complete class list (REA's metadata reader stops at its record limit), `strings` and `grep` for strings (REA's string search needs Hopper or Ghidra, neither usable), a byte search over all split images. Evidence in `research/macos-15.6.1-24G90/notes/launchpad-location.md`.
- **Environment:** REF-ENV-001
- **Date:** 2026-10-16
- **Notes:** `Dock.app/Contents/XPCServices/DockHelper.xpc` (bundle ID `com.apple.dock.helper`) contains 345 of Dock's classes, including the Launchpad classes except `ECSBGroupPage` and `LPPlaceholder`, plus 6 of its own, and links AppKit and Carbon in addition. Whether it takes part in Launchpad at runtime is not known yet. That Launchpad runs in the Dock process is inferred from static evidence only; runtime confirmation waits for the Frida attach (REF-ENV-003). Dock's other five XPC services contain no `launchpad` string. The export check sees C and Objective-C symbols only: Swift exports of split images are not visible to the tools used. The byte search covers every image.

## REF-ARCH-002 Launchpad controller and view classes

- **Status:** measured
- **Value:** Objective-C classes in the Dock executable.
  - Controller: `Springboard : NSObject <ECModalEventHandler, ECEventHandlingDelegate, ECSBDelegate, ECSBDataSource, ECSBActionHandling, CALayerDelegate>`, `LPSpringboard : Springboard <DOCKExtraDelegate, DOCKGestureHandler>`, `LPSpringboardConnection : NSObject`, `SpringboardDragCacheItem : NSObject`
  - Springboard UI: `ECSBSpringboard : NSObject <ECPagerSource, ECSBGridPagerSource, ECSBGridActionHandling, ECSBDataSourceClient, ECKeyboardNavigating, ECEventHandling>`, `ECSBEnvironment : NSObject`, `ECSBEventHandler : NSObject`, `ECSBDragCapture : NSObject <ECEventHandlingDelegate>`
  - Pages and folders: `ECSBPager : ECPager <ECSBGridPagerSourceClient, ECAlertPanelDelegate, ECEventHandling>`, `ECSBGroupPager : ECSBPager`, `ECSBPage : ECPage <ECLayerSource, ECEventHandlingDelegate, ECKeyboardNavigating, ECSBGridDataSource, ECSBGridDataSourceClient>`, `ECSBGroupPage : ECSBPage`, `ECSBGroup : NSObject <ECSBGridDataSource, ECLayerSource, ECLayerSourceClient, ECSBGridPagerSource, ECKeyboardNavigating, ECEventHandlingDelegate>`
  - Items: `ECSBItem : NSObject`, `ECSBContainerItem : ECSBItem`, `ECSBSpringboardItem : ECSBContainerItem`, `ECSBPageItem : ECSBContainerItem`, `ECSBGroupItem : ECSBContainerItem`, `ECSBPlaceholderItem : ECSBItem`, `ECSBPlaceholderPageItem : ECSBPageItem`, `ECSBPlaceholderGroupItem : ECSBGroupItem`, `ECSBOverflowItem : NSObject`
  - Layers: `ECSBLayer : ECPagerLayer <ECEventHandlingDelegate>`, `ECSBGroupLayer : ECPagerLayer`, `ECSBGridLayer : ECGridLayer`, `ECSBItemLayer : CALayer <ECSBGridItemSource, ECEventHandlingDelegate>`, `ECSBGroupItemLayer : ECSBItemLayer`, `ECSBPlaceholderItemLayer : ECSBItemLayer`, `ECSBLabelLayer : CALayer`, `ECSBProgressLabelLayer : ECSBLabelLayer`
  - Dragging: `ECSBDragState : NSObject`, `ECSBBeginningDragState : ECSBDragState`, `ECSBMoveItemDragState : ECSBDragState`, `ECSBChangePageDragState : ECSBMoveItemDragState`, `ECSBOpenGroupDragState : ECSBMoveItemDragState`, `ECSBCloseGroupDragState : ECSBMoveItemDragState`
  - Search and games pages: `SBSearchPage : NSObject`, `SBGamePage : NSObject`
  - Paging base classes: `ECPager : NSObject <ECEventHandling, ECEventHandlingDelegate, ECKeyboardNavigating>`, `ECPage : NSObject`, `ECPagerLayer : CALayer <ECEventHandling>`, `ECPagerControlLayer : CALayer <ECEventHandlingDelegate>`, `ECPagerIndicatorLayer : CALayer`, `ECGridLayer : CALayer`
  - Protocols: `ECSBActionHandling`, `ECSBDataSource`, `ECSBDataSourceClient`, `ECSBDelegate`, `ECSBGridActionHandling`, `ECSBGridDataSource`, `ECSBGridDataSourceClient`, `ECSBGridItemSource`, `ECSBGridPagerSource <ECPagerSource>`, `ECSBGridPagerSourceClient`
- **Source:** REA `inspect_native_dispatch_metadata` on the Dock executable (arm64e slice), cross-checked with `dyld_info -objc`; evidence in `research/macos-15.6.1-24G90/notes/launchpad-location.md` and `dock-classes.txt` beside it.
- **Environment:** REF-ENV-001
- **Date:** 2026-10-16
- **Notes:** Grouping by role follows the class names and has not been checked against behavior. Dock has many more classes with the `EC` prefix; only those the Launchpad classes inherit from are listed. Dock also contains Swift modules named DockCore, EyeCandyCore, EyeCandyGraphics, EyeCandySwift and EyeCandyAccessibility.

## REF-ARCH-003 Launchpad data model and storage classes

- **Status:** measured
- **Value:** Objective-C classes in the Dock executable.
  - Items: `LPItem : NSObject`, `LPRunnable : LPItem <LPLayoutItem>`, `LPApp : LPRunnable`, `LPDownloadingApp : LPItem <LPItemContainer, LPItemProgress, LPLayoutItem>`, `LPGroup : LPItem <LPItemContainer, LPItemProgress>`, `LPPage : LPGroup`, `LPRoot : LPPage`, `LPPlaceholder : LPItem`
  - Layout: `LPLayout : NSObject`, `LPLayoutExcludeList : NSObject`, `LPLayoutIncludeAsGameList : NSObject`, category `NSMutableArray (LPLayoutArrayExtension)`
  - Apps: `LPAppManager : NSObject`, `LPAppSource : NSObject <LPStorageStorable>`, `LPAppNSCacheDelegate : NSObject <NSCacheDelegate>`, `LPAppTreeNode : NSObject`, `LPAppTree : LPAppTreeNode`, `LPAppTreeApp : LPAppTreeNode`
  - Storage: `LPStorage : NSObject`, `LPStorageTransaction : NSObject`, `LPStorageStatementCache : NSObject`, `LPDatabaseException : NSException`, `LPCompletionBlock : NSObject`
  - Protocols: `LPItemContainer`, `LPItemProgress`, `LPLayoutItem`, `LPStorageStorable`
- **Source:** as REF-ARCH-002.
- **Environment:** REF-ENV-001
- **Date:** 2026-10-16
- **Notes:** REA's metadata reader did not decode categories; the category comes from `dyld_info -objc`.

## REF-ARCH-004 Launchpad persistent state

- **Status:** measured
- **Value:**
  - Layout database: `com.apple.dock.launchpad/db/db` in the per-user directory that `getconf DARWIN_USER_DIR` prints, an SQLite 3 file with `db-wal` and `db-shm` beside it.
  - Default layout shipped with Dock: `Dock.app/Contents/Resources/LaunchPadLayout.plist`.
  - Preference key names found in the Dock executable: `springboard-columns`, `springboard-rows`, `springboard-show-duration`, `springboard-hide-duration`, `springboard-page-duration`, `springboard-zoom-style`, `springboard-reverse-scroll-gesture`, `springboard-edit-group-title`, `ResetLaunchPad`.
- **Source:** directory listing and file header read in the reference VM over SSH; Dock.app contents fetched by `tools/re/vm-fetch.sh`; `strings` and `grep` on the Dock executable. Evidence in `research/macos-15.6.1-24G90/notes/launchpad-location.md`.
- **Environment:** REF-ENV-001
- **Date:** 2026-10-16
- **Notes:** Only the key names are recorded. Their defaults, units and the preference domain they are read from are not measured.

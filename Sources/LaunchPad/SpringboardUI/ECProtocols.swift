import QuartzCore

// The protocols between the controller, the grid components and their layers (REF-ARCH-006,
// REF-ARCH-013). Selectors and optionality are the original's; only the methods the grid tree uses
// are declared. Optional methods are sent without checking unless the original checks.

/// The controller as the grid's data source.
@MainActor
@objc(ECSBDataSource)
protocol ECSBDataSource: NSObjectProtocol {
    /// `items`: the model children of `item` (the layout root's when `item` is nil); `kind`: `page`,
    /// `group` or `item`.
    @objc(valueForKey:ofItem:withInfo:)
    func value(forKey key: String, ofItem item: AnyObject?, withInfo info: AnyObject?) -> AnyObject?
}

/// The source of a pager's pages.
@MainActor
@objc(ECPagerSource)
protocol ECPagerSource: NSObjectProtocol {
    @objc(numberOfPagesForPager:)
    func numberOfPages(for pager: ECPager) -> UInt

    @objc(makePageForPager:atIndex:)
    func makePage(for pager: ECPager, at index: UInt) -> ECPage?

    @objc(pageItemsForPager:)
    func pageItems(for pager: ECPager) -> NSArray?

    @objc(layoutPage:forPager:)
    optional func layoutPage(_ page: ECPage, for pager: ECPager)

    @objc(willChangeToPageIndex:)
    optional func willChangeToPageIndex(_ index: UInt)

    @objc(didChangeToPageIndex:)
    optional func didChangeToPageIndex(_ index: UInt)
}

/// The source of a grid layer's item layers and their contents.
@MainActor
@objc(ECLayerSource)
protocol ECLayerSource: NSObjectProtocol {
    @objc(numberOfItemsForLayer:)
    func numberOfItems(for layer: CALayer) -> UInt

    @objc(setContentInLayers:withDataRange:forLayer:usingScaleFactor:)
    func setContent(inLayers layers: NSArray, withDataRange range: NSRange, for layer: CALayer, usingScaleFactor scaleFactor: Float)

    @objc(makeLayerForLayer:)
    optional func makeLayer(for layer: CALayer) -> CALayer?

    @objc(makeLayerForLayer:atIndex:)
    optional func makeLayer(for layer: CALayer, at index: UInt) -> CALayer?
}

/// Told by a layer source that its items changed.
@MainActor
@objc(ECLayerSourceClient)
protocol ECLayerSourceClient: NSObjectProtocol {
    @objc(layerSourceInvalidated:)
    func layerSourceInvalidated(_ source: ECLayerSource?)
}

/// What an item layer asks for its contents: a page or a folder.
@MainActor
@objc(ECSBGridDataSource)
protocol ECSBGridDataSource: NSObjectProtocol {
    @objc(gridValueForKey:atIndex:withItemInfo:)
    func gridValue(forKey key: String, at index: UInt, withItemInfo info: NSDictionary?) -> AnyObject?
}

/// An item layer that takes its contents from a grid data source.
@MainActor
@objc(ECSBGridItemSource)
protocol ECSBGridItemSource: NSObjectProtocol {
    @objc(setContentFromDataSource:atIndex:withItemInfo:)
    func setContent(fromDataSource dataSource: ECSBGridDataSource, at index: UInt, withItemInfo info: NSDictionary?)

    @objc var isGroupItem: Bool { get }
}

/// What handles events itself: the event methods take an `ECEvent` and return whether they handled
/// it; all optional, sent after `respondsToSelector:` (REF-ARCH-006, REF-OVERLAY-009).
@MainActor
@objc(ECEventHandling)
protocol ECEventHandling: NSObjectProtocol {
    @objc(leftMouseDown:)
    optional func leftMouseDown(_ event: ECEvent) -> Bool

    @objc(leftMouseUp:)
    optional func leftMouseUp(_ event: ECEvent) -> Bool

    @objc(leftMouseDragged:)
    optional func leftMouseDragged(_ event: ECEvent) -> Bool

    @objc(keyDown:)
    optional func keyDown(_ event: ECEvent) -> Bool

    @objc(keyUp:)
    optional func keyUp(_ event: ECEvent) -> Bool

    @objc(flagsChanged:)
    optional func flagsChanged(_ event: ECEvent) -> Bool

    @objc(scrollWheel:)
    optional func scrollWheel(_ event: ECEvent) -> Bool

    @objc(gesture:)
    optional func gesture(_ event: ECEvent) -> Bool

    @objc(lostKeyFocus:)
    optional func lostKeyFocus(_ event: ECEvent?)
}

/// What handles a layer's events as the layer's `eventDelegate`: the same methods with the layer as
/// the second argument; all optional (REF-ARCH-006, REF-OVERLAY-009). The dispatcher asks each
/// implementer with `respondsToSelector:`, so they are not declared here.
@MainActor
@objc(ECEventHandlingDelegate)
protocol ECEventHandlingDelegate: NSObjectProtocol {}

/// The controller as the delegate of the grid components. The pager tells it when editing begins and
/// ends; no class of the original implements either method (research paper §5.9). It also tells it
/// before and after the current page changes, with the model page (REF-PAGING-001), and before and
/// after the selected item changes, with the two model items (REF-KEYBOARD-003).
@MainActor
@objc(ECSBDelegate)
protocol ECSBDelegate: NSObjectProtocol {
    @objc(willChangeToPage:)
    optional func willChangeToPage(_ page: AnyObject?)

    @objc(didChangeToPage:)
    optional func didChangeToPage(_ page: AnyObject?)

    @objc optional func didBeginEditing()
    @objc optional func didEndEditing()

    @objc(selectionWillChangeFromItem:toItem:inPager:)
    optional func selectionWillChange(fromItem oldItem: AnyObject?, toItem newItem: AnyObject?, inPager pager: AnyObject?)

    @objc(selectionDidChangeFromItem:toItem:inPager:)
    optional func selectionDidChange(fromItem oldItem: AnyObject?, toItem newItem: AnyObject?, inPager pager: AnyObject?)
}

/// What moves the selection with the navigation keys: the type is Up 0, Down 1, Left 2, Right 3,
/// next page 4, previous page 5, Home 6, End 7, Page Up 8, Page Down 9; the event is nil when the
/// navigation does not come from a key (REF-KEYBOARD-001, REF-KEYBOARD-002). The optional
/// `selectedIndex` is not used by the main grid.
@MainActor
@objc(ECKeyboardNavigating)
protocol ECKeyboardNavigating: NSObjectProtocol {
    @objc(navigate:withEvent:)
    func navigate(_ type: Int64, with event: ECEvent?) -> Bool
}

/// The controller as the handler of the grid's item actions.
@MainActor
@objc(ECSBActionHandling)
protocol ECSBActionHandling: NSObjectProtocol {
    @objc(performActionForItem:withEvent:sender:)
    func performAction(forItem item: AnyObject?, with event: ECEvent?, sender: AnyObject?)

    @objc(cancelActionWithEvent:sender:)
    optional func cancelAction(with event: ECEvent?, sender: AnyObject?)
}

/// The main grid's handler of the actions on the grid (`ECSBPager.gridActionHandler`).
@MainActor
@objc(ECSBGridActionHandling)
protocol ECSBGridActionHandling: NSObjectProtocol {
    @objc(performGridActionAtIndex:withEvent:sender:)
    func performGridAction(at index: UInt, with event: ECEvent?, sender: AnyObject?)

    @objc(cancelGridActionWithEvent:sender:)
    optional func cancelGridAction(with event: ECEvent?, sender: AnyObject?)
}

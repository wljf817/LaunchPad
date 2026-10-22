import Foundation

/// A page of the main grid or of a folder; its items are the page's apps and folders. It has a page
/// once the pager has made one for it (research paper §6.1, §6.2).
@MainActor
@objc(ECSBPageItem)
class ECSBPageItem: ECSBContainerItem {
    @objc weak var page: ECSBPage?
}

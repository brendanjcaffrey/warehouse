import SwiftUI
import UIKit

/// scrolls the collection view backing a list directly; scrollviewreader's
/// scrollto builds every row between the top & the target to find its
/// offset, which freezes for seconds on big lists
@MainActor
final class ListScroller {
    fileprivate weak var anchor: UIView?

    /// jumps to a row without animation; fails when the collection view
    /// can't be found or hasn't picked up the caller's sections yet
    func scrollToRow(section: Int, row: Int, expectedSections: Int) -> Bool {
        guard let collectionView = findCollectionView(),
              collectionView.numberOfSections == expectedSections,
              section < expectedSections,
              row < collectionView.numberOfItems(inSection: section) else { return false }
        collectionView.scrollToItem(
            at: IndexPath(item: row, section: section), at: .centeredVertically, animated: false)
        return true
    }

    private func findCollectionView() -> UICollectionView? {
        // the collection view lives in a sibling subtree of the background
        // hosting the anchor, a few levels up
        var view = anchor?.superview
        for _ in 0..<8 {
            guard let current = view else { return nil }
            if let found = current.firstCollectionView() {
                return found
            }
            view = current.superview
        }
        return nil
    }
}

/// invisible view dropped behind a list so the scroller can find the list's
/// collection view at scroll time
struct ListScrollerAnchor: UIViewRepresentable {
    let scroller: ListScroller

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        scroller.anchor = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        scroller.anchor = uiView
    }
}

private extension UIView {
    func firstCollectionView() -> UICollectionView? {
        for subview in subviews {
            if let match = subview as? UICollectionView {
                return match
            }
            if let match = subview.firstCollectionView() {
                return match
            }
        }
        return nil
    }
}

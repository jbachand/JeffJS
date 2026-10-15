import Foundation
import Synchronization

// MARK: - Sibling positions
//
// `nextSibling`, `previousElementSibling`, `:nth-child`, `:last-child` ... all
// need a node's position among its parent's children. Finding it by scanning
// (and copying) the children array made a loop over n siblings O(n^2).
//
// Each node caches its position in its own `State` (`posIndex`,
// `posElementIndex`, `posElementCount`), tagged with the parent's
// `childrenVersion` at the time. Every change to a parent's `children` bumps
// that version (`State.children.didSet`), and every change of a node's parent
// link clears its tag, so a tag equal to the parent's current version is
// valid. A miss seeds every child of that parent in one pass, so a walk along
// the siblings pays one O(n) pass per mutation, not one per node.
//
// Threads: the same rules as the rest of `DOMNode` -- each step takes one
// node's lock, never two at once. A reader racing the single writer sees the
// positions of the state before or after a mutation (it re-checks that the
// slot it reads still holds the node, and falls back to a scan otherwise); a
// seeding pass writes only into children whose parent link is still the
// parent it read, under the child's lock, where the writer resets the tag.

nonisolated struct DOMSiblingPosition {
    let parent: DOMNode
    let index: Int
    let elementIndex: Int
    let elementCount: Int
}

extension DOMNode {

    /// This node's position among its parent's children (nil without a parent).
    func siblingPosition() -> DOMSiblingPosition? {
        guard let parent = self.parent else { return nil }
        let parentVersion = parent.state.withLock { $0.childrenVersion }
        let own = state.withLock { s -> DOMSiblingPosition? in
            guard s.posVersion == parentVersion, s.parent === parent else { return nil }
            return DOMSiblingPosition(parent: parent, index: s.posIndex,
                                      elementIndex: s.posElementIndex, elementCount: s.posElementCount)
        }
        if let own { return own }
        return parent.seedChildPositions(for: self)
    }

    /// Stamps every child of `self` with its position and returns `node`'s.
    private func seedChildPositions(for node: DOMNode) -> DOMSiblingPosition? {
        let (snapshot, version) = state.withLock { ($0.children, $0.childrenVersion) }
        var elementCount = 0
        for child in snapshot where child.nodeType == .element { elementCount += 1 }
        var result: DOMSiblingPosition?
        var seenElements = 0
        for (i, child) in snapshot.enumerated() {
            let elementIndex = seenElements
            if child.nodeType == .element { seenElements += 1 }
            child.state.withLock {
                guard $0.parent === self else { return }
                $0.posVersion = version
                $0.posIndex = i
                $0.posElementIndex = elementIndex
                $0.posElementCount = elementCount
            }
            if child === node {
                result = DOMSiblingPosition(parent: self, index: i, elementIndex: elementIndex, elementCount: elementCount)
            }
        }
        return result
    }

    /// The sibling `offset` places from this node (any node type), or nil.
    func sibling(offset: Int) -> DOMNode? {
        guard let position = siblingPosition() else { return nil }
        let target = position.index + offset
        return position.parent.state.withLock { s -> DOMNode? in
            // The slot must still hold this node (a mutation since the read).
            guard position.index < s.children.count, s.children[position.index] === self else {
                guard let i = s.children.firstIndex(where: { $0 === self }) else { return nil }
                let t = i + offset
                return t >= 0 && t < s.children.count ? s.children[t] : nil
            }
            return target >= 0 && target < s.children.count ? s.children[target] : nil
        }
    }

    /// The nearest following (`forward`) or preceding sibling that is an element.
    func elementSibling(forward: Bool) -> DOMNode? {
        guard let position = siblingPosition() else { return nil }
        return position.parent.state.withLock { s -> DOMNode? in
            var i: Int
            if position.index < s.children.count, s.children[position.index] === self {
                i = position.index
            } else if let found = s.children.firstIndex(where: { $0 === self }) {
                i = found
            } else {
                return nil
            }
            let step = forward ? 1 : -1
            i += step
            while i >= 0 && i < s.children.count {
                if s.children[i].nodeType == .element { return s.children[i] }
                i += step
            }
            return nil
        }
    }
}

// JeffJSList.swift
// JeffJS - 1:1 Swift port of QuickJS JavaScript engine
//
// Port of QuickJS list.h — Linux-kernel-style intrusive doubly-linked list.
//
// In the original C code, list_head is embedded directly inside structs using
// offsetof/container_of macros. In Swift we use a class-based approach: each
// list node holds an unowned reference to its owner object, and iteration
// yields owner references via the generic ListEntry wrapper.

import Foundation

// MARK: - ListHead

/// Intrusive doubly-linked list node. When used as a sentinel (head of list),
/// an empty list has both `prev` and `next` pointing to itself.
final class ListHead {
    var prev: ListHead!
    var next: ListHead!

    /// Owner object reference for container_of equivalent.
    /// Stored as Any to support heterogeneous owner types.
    weak var _owner: AnyObject?

    /// Initialize a standalone node as an empty circular list (sentinel).
    init() {
        self.prev = self
        self.next = self
    }

    /// Initialize a node with a known owner for list_entry retrieval.
    init(owner: AnyObject) {
        self.prev = self
        self.next = self
        self._owner = owner
    }
}

// MARK: - Core List Operations

/// Initialize (or re-initialize) a list head as an empty list.
/// Equivalent to `INIT_LIST_HEAD` / `init_list_head` in QuickJS.
func initListHead(_ head: ListHead) {
    head.prev = head
    head.next = head
}

/// Returns `true` if the list contains no elements (head points to itself).
/// Equivalent to `list_empty` in QuickJS.
func listEmpty(_ head: ListHead) -> Bool {
    return head.next === head
}

/// Returns `true` if the list contains no elements.
/// Alias for `listEmpty` matching the C name `list_is_empty`.
func listIsEmpty(_ head: ListHead) -> Bool {
    return head.next === head
}

// MARK: - Insertion

/// Internal: insert `entry` between `prev` and `next`.
/// Equivalent to `__list_add` in the Linux kernel list implementation.
private func _listAdd(_ entry: ListHead, _ prev: ListHead, _ next: ListHead) {
    next.prev = entry
    entry.next = next
    entry.prev = prev
    prev.next = entry
}

/// Insert `entry` immediately after `head`.
/// Equivalent to `list_add` in QuickJS (adds to front of list).
///
/// For a list `H <-> A <-> B`, calling `listAdd(X, H)` produces `H <-> X <-> A <-> B`.
func listAdd(_ entry: ListHead, _ head: ListHead) {
    _listAdd(entry, head, head.next)
}

/// Insert `entry` immediately before `head` (i.e. at the tail of the list).
/// Equivalent to `list_add_tail` in QuickJS.
///
/// For a list `H <-> A <-> B`, calling `listAddTail(X, H)` produces `H <-> A <-> B <-> X`.
func listAddTail(_ entry: ListHead, _ head: ListHead) {
    _listAdd(entry, head.prev, head)
}

// MARK: - Removal

/// Remove `entry` from its current list by relinking its neighbors.
/// After removal, `entry.prev` and `entry.next` are set to `nil` to make
/// accidental use obvious. Equivalent to `list_del` in QuickJS.
func listDel(_ entry: ListHead) {
    entry.prev.next = entry.next
    entry.next.prev = entry.prev
    entry.prev = nil
    entry.next = nil
}

/// Remove `entry` from its current list and re-initialize it as an empty
/// list (self-referencing sentinel). Useful when the node may be re-inserted
/// later. Equivalent to `list_del_init` in the Linux kernel.
func listDelInit(_ entry: ListHead) {
    entry.prev.next = entry.next
    entry.next.prev = entry.prev
    entry.prev = entry
    entry.next = entry
}

// MARK: - Move

/// Remove `entry` from its current list and insert it after `head`.
func listMoveToFront(_ entry: ListHead, _ head: ListHead) {
    // Unlink
    entry.prev.next = entry.next
    entry.next.prev = entry.prev
    // Insert after head
    _listAdd(entry, head, head.next)
}

/// Remove `entry` from its current list and insert it before `head` (tail).
func listMoveToTail(_ entry: ListHead, _ head: ListHead) {
    // Unlink
    entry.prev.next = entry.next
    entry.next.prev = entry.prev
    // Insert before head
    _listAdd(entry, head.prev, head)
}

// MARK: - Splice

/// Splice the contents of `list` into the position after `head`.
/// `list` will be empty after this operation.
func listSplice(_ list: ListHead, _ head: ListHead) {
    guard !listEmpty(list) else { return }
    let first = list.next!
    let last = list.prev!

    let at = head.next!

    head.next = first
    first.prev = head

    last.next = at
    at.prev = last

    // Re-init source list as empty
    initListHead(list)
}

// MARK: - Count

/// Returns the number of entries in the list (O(n) traversal).
func listCount(_ head: ListHead) -> Int {
    var count = 0
    var node = head.next!
    while node !== head {
        count += 1
        node = node.next
    }
    return count
}

// MARK: - Iteration: list_for_each

/// Iterate over every node in the list, calling `body` with each `ListHead`.
/// Equivalent to `list_for_each` in QuickJS.
///
/// **Not safe for removal during iteration** — use `listForEachSafe` if
/// entries may be removed inside the closure.
func listForEach(_ head: ListHead, body: (ListHead) -> Void) {
    var node = head.next!
    while node !== head {
        body(node)
        node = node.next
    }
}

/// Iterate over every node in reverse order (tail to front).
/// Equivalent to `list_for_each_prev` in the Linux kernel.
func listForEachPrev(_ head: ListHead, body: (ListHead) -> Void) {
    var node = head.prev!
    while node !== head {
        body(node)
        node = node.prev
    }
}

/// Iterate over every node in the list, safe for removal of the current node.
/// Equivalent to `list_for_each_safe` in QuickJS.
///
/// The next pointer is captured before `body` executes, so calling
/// `listDel` on the current node inside `body` is safe.
func listForEachSafe(_ head: ListHead, body: (ListHead) -> Void) {
    var node = head.next!
    while node !== head {
        let nextNode = node.next!
        body(node)
        node = nextNode
    }
}

/// Reverse-direction safe iteration.
/// Equivalent to `list_for_each_prev_safe` in the Linux kernel.
func listForEachPrevSafe(_ head: ListHead, body: (ListHead) -> Void) {
    var node = head.prev!
    while node !== head {
        let prevNode = node.prev!
        body(node)
        node = prevNode
    }
}

// MARK: - list_entry / container_of Equivalent

/// Retrieve the owner object of type `T` from a `ListHead` node.
/// This is the Swift equivalent of the C `list_entry` / `container_of` macro.
///
/// Usage:
/// ```
/// let obj: MyObject = listEntry(node)
/// ```
///
/// - Precondition: The `ListHead` must have been created with `init(owner:)`
///   and the owner must still be alive.
/// - Returns: The owner cast to type `T`.
func listEntry<T: AnyObject>(_ node: ListHead) -> T {
    return node._owner as! T
}

/// Retrieve the owner object of type `T` from a `ListHead` node, returning
/// `nil` if the owner has been deallocated or is not of the expected type.
func listEntryOptional<T: AnyObject>(_ node: ListHead) -> T? {
    return node._owner as? T
}

// MARK: - Typed Iteration Helpers

/// Iterate over list entries, automatically casting each node's owner to `T`.
/// Equivalent to `list_for_each_entry` in the Linux kernel.
func listForEachEntry<T: AnyObject>(_ head: ListHead, type: T.Type, body: (T) -> Void) {
    var node = head.next!
    while node !== head {
        if let entry: T = listEntryOptional(node) {
            body(entry)
        }
        node = node.next
    }
}

/// Iterate over list entries with safe removal, casting each node's owner to `T`.
/// Equivalent to `list_for_each_entry_safe` in the Linux kernel.
func listForEachEntrySafe<T: AnyObject>(_ head: ListHead, type: T.Type, body: (T) -> Void) {
    var node = head.next!
    while node !== head {
        let nextNode = node.next!
        if let entry: T = listEntryOptional(node) {
            body(entry)
        }
        node = nextNode
    }
}

/// Iterate over list entries in reverse, casting each node's owner to `T`.
func listForEachEntryReverse<T: AnyObject>(_ head: ListHead, type: T.Type, body: (T) -> Void) {
    var node = head.prev!
    while node !== head {
        if let entry: T = listEntryOptional(node) {
            body(entry)
        }
        node = node.prev
    }
}

// MARK: - Sequence Conformance

/// A `Sequence`-conforming wrapper that allows using `for ... in` syntax
/// to iterate over list entries.
///
/// Usage:
/// ```
/// for node in ListSequence(head) {
///     // node is ListHead
/// }
/// ```
struct ListSequence: Sequence {
    let head: ListHead

    init(_ head: ListHead) {
        self.head = head
    }

    func makeIterator() -> ListIterator {
        return ListIterator(head: head)
    }
}

/// Iterator for `ListSequence`.
struct ListIterator: IteratorProtocol {
    let head: ListHead
    var current: ListHead?

    init(head: ListHead) {
        self.head = head
        self.current = head.next
    }

    mutating func next() -> ListHead? {
        guard let node = current, node !== head else {
            return nil
        }
        current = node.next
        return node
    }
}

/// A `Sequence`-conforming wrapper for safe iteration (allows removal during
/// iteration). Captures the next pointer before yielding each element.
struct ListSequenceSafe: Sequence {
    let head: ListHead

    init(_ head: ListHead) {
        self.head = head
    }

    func makeIterator() -> ListIteratorSafe {
        return ListIteratorSafe(head: head)
    }
}

/// Iterator that pre-captures the next pointer, safe for element removal.
struct ListIteratorSafe: IteratorProtocol {
    let head: ListHead
    var current: ListHead?
    var nextNode: ListHead?

    init(head: ListHead) {
        self.head = head
        self.current = head.next
        self.nextNode = head.next?.next
    }

    mutating func next() -> ListHead? {
        guard let node = current, node !== head else {
            return nil
        }
        current = nextNode
        nextNode = nextNode?.next
        return node
    }
}

/// A typed `Sequence` wrapper that yields owner objects of type `T`.
///
/// Usage:
/// ```
/// for obj in TypedListSequence<MyClass>(head) {
///     // obj is MyClass
/// }
/// ```
struct TypedListSequence<T: AnyObject>: Sequence {
    let head: ListHead

    init(_ head: ListHead) {
        self.head = head
    }

    func makeIterator() -> TypedListIterator<T> {
        return TypedListIterator<T>(head: head)
    }
}

/// Iterator for `TypedListSequence`.
struct TypedListIterator<T: AnyObject>: IteratorProtocol {
    let head: ListHead
    var current: ListHead?

    init(head: ListHead) {
        self.head = head
        self.current = head.next
    }

    mutating func next() -> T? {
        while let node = current, node !== head {
            current = node.next
            if let entry: T = listEntryOptional(node) {
                return entry
            }
        }
        return nil
    }
}

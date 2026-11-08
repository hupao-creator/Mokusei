import Foundation

/// A catalog transaction retains earlier snapshots while changing a few records.
/// Copying a Swift Dictionary/Array here would copy the entire catalog on its
/// first write. These immutable AVL paths share everything outside the change.
public struct RuntimeRecordCollection<Value: Sendable>: Sendable, Sequence {
    fileprivate struct Entry: Sendable {
        let id: JSONText
        let value: Value
    }
    private var positions = RuntimeRecordTree<JSONText, Int>()
    private var entries = RuntimeRecordTree<Int, Entry>()
    private var nextPosition = 0

    public init() {}
    public var count: Int { entries.count }
    public var isEmpty: Bool { count == 0 }
    public subscript(_ id: JSONText) -> Value? {
        positions[id].flatMap { entries[$0]?.value }
    }
    public var ids: [JSONText] { entries.map { $0.id } }
    public func position(of id: JSONText) -> Int? { positions[id] }

    public mutating func updateValue(_ value: Value, forKey id: JSONText) {
        let position: Int
        if let existing = positions[id] { position = existing }
        else {
            position = nextPosition
            nextPosition += 1
            positions.set(position, forKey: id)
        }
        entries.set(Entry(id: id, value: value), forKey: position)
    }

    @discardableResult
    public mutating func removeValue(forKey id: JSONText) -> Value? {
        guard let position = positions[id] else { return nil }
        let previous = entries[position]?.value
        positions.remove(id)
        entries.remove(position)
        return previous
    }

    /// Explicit order changes necessarily inspect the supplied order. Ordinary
    /// upserts preserve their slot and never enumerate the other records.
    public mutating func reorder(_ order: [JSONText]) throws {
        guard order.count == count else {
            throw RuntimeError("REVISION_GAP", "Collection order omitted runtime records")
        }
        var next = Self()
        for id in order {
            guard next[id] == nil, let value = self[id] else {
                throw RuntimeError("REVISION_GAP", "Collection order references missing or duplicate records")
            }
            next.updateValue(value, forKey: id)
        }
        self = next
    }

    public func sharesStorage(with other: Self) -> Bool { entries.sharesStorage(with: other.entries) }

    public struct Iterator: IteratorProtocol {
        fileprivate var iterator: RuntimeRecordTree<Int, Entry>.Iterator
        public mutating func next() -> Value? { iterator.next()?.value }
    }
    public func makeIterator() -> Iterator { Iterator(iterator: entries.makeIterator()) }
}

extension RuntimeRecordCollection: Equatable where Value: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sharesStorage(with: rhs) || (lhs.count == rhs.count && lhs.elementsEqual(rhs))
    }
}

extension RuntimeRecordCollection: Hashable where Value: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(count)
        for value in self { hasher.combine(value) }
    }
}

extension JSONText: Comparable {
    public static func < (lhs: JSONText, rhs: JSONText) -> Bool {
        lhs.codeUnits.lexicographicallyPrecedes(rhs.codeUnits)
    }
}

fileprivate struct RuntimeRecordTree<Key: Comparable & Sendable, Value: Sendable>: Sendable, Sequence {
    final class Node: Sendable {
        let key: Key
        let value: Value
        let left: Node?
        let right: Node?
        let height: Int
        let count: Int

        init(_ key: Key, _ value: Value, _ left: Node? = nil, _ right: Node? = nil) {
            self.key = key; self.value = value; self.left = left; self.right = right
            height = 1 + Swift.max(left?.height ?? 0, right?.height ?? 0)
            count = 1 + (left?.count ?? 0) + (right?.count ?? 0)
        }
    }
    private var root: Node?
    init() {}
    var count: Int { root?.count ?? 0 }

    subscript(_ key: Key) -> Value? {
        var node = root
        while let current = node {
            if key < current.key { node = current.left }
            else if current.key < key { node = current.right }
            else { return current.value }
        }
        return nil
    }

    mutating func set(_ value: Value, forKey key: Key) { root = Self.inserting(root, key: key, value: value) }
    mutating func remove(_ key: Key) { root = Self.removing(root, key: key) }
    func sharesStorage(with other: Self) -> Bool { root === other.root }

    private static func inserting(_ node: Node?, key: Key, value: Value) -> Node {
        guard let node else { return Node(key, value) }
        if key < node.key { return balanced(Node(node.key, node.value, inserting(node.left, key: key, value: value), node.right)) }
        if node.key < key { return balanced(Node(node.key, node.value, node.left, inserting(node.right, key: key, value: value))) }
        return Node(key, value, node.left, node.right)
    }

    private static func removing(_ node: Node?, key: Key) -> Node? {
        guard let node else { return nil }
        if key < node.key { return balanced(Node(node.key, node.value, removing(node.left, key: key), node.right)) }
        if node.key < key { return balanced(Node(node.key, node.value, node.left, removing(node.right, key: key))) }
        guard let left = node.left else { return node.right }
        guard let right = node.right else { return left }
        var successor = right
        while let next = successor.left { successor = next }
        return balanced(Node(successor.key, successor.value, left, removing(right, key: successor.key)))
    }

    private static func balanced(_ node: Node) -> Node {
        let balance = (node.left?.height ?? 0) - (node.right?.height ?? 0)
        if balance > 1, let left = node.left {
            if (left.left?.height ?? 0) < (left.right?.height ?? 0) {
                return rotateRight(Node(node.key, node.value, rotateLeft(left), node.right))
            }
            return rotateRight(node)
        }
        if balance < -1, let right = node.right {
            if (right.right?.height ?? 0) < (right.left?.height ?? 0) {
                return rotateLeft(Node(node.key, node.value, node.left, rotateRight(right)))
            }
            return rotateLeft(node)
        }
        return node
    }

    private static func rotateLeft(_ node: Node) -> Node {
        let next = node.right!
        return Node(next.key, next.value, Node(node.key, node.value, node.left, next.left), next.right)
    }
    private static func rotateRight(_ node: Node) -> Node {
        let next = node.left!
        return Node(next.key, next.value, next.left, Node(node.key, node.value, next.right, node.right))
    }

    struct Iterator: IteratorProtocol {
        private var stack: [Node] = []
        init(_ root: Node?) { descend(root) }
        private mutating func descend(_ root: Node?) {
            var node = root
            while let current = node { stack.append(current); node = current.left }
        }
        mutating func next() -> Value? {
            guard let node = stack.popLast() else { return nil }
            descend(node.right)
            return node.value
        }
    }
    func makeIterator() -> Iterator { Iterator(root) }
}

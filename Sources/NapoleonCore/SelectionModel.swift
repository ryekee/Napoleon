/// Navigation state machine for window selection with grid navigation and reset.
public struct SelectionModel: Sendable {
    public private(set) var count: Int
    public private(set) var index: Int

    /// Initialize with a count and optional initial index.
    /// The initial index is clamped to [0, max(0, count-1)].
    public init(count: Int, initial: Int = 0) {
        self.count = count
        self.index = Self.clamp(initial, to: 0, max(0, count - 1))
    }

    /// Move to the next item (wraps around).
    /// Uses (index + 1 + count) % count; if count == 0, keeps index at 0.
    public mutating func next() {
        if count == 0 {
            index = 0
        } else {
            index = (index + 1) % count
        }
    }

    /// Move to the previous item (wraps around).
    /// Uses (index - 1 + count) % count; if count == 0, keeps index at 0.
    public mutating func previous() {
        if count == 0 {
            index = 0
        } else {
            index = (index - 1 + count) % count
        }
    }

    /// Move in a grid with specified columns and direction.
    /// Clamps column and row at edges.
    public mutating func moveInGrid(dx: Int, dy: Int, columns: Int) {
        guard columns > 0, count > 0 else { return }

        let row = index / columns
        let col = index % columns
        let lastRow = (count - 1) / columns

        let newCol = Self.clamp(col + dx, to: 0, columns - 1)
        let newRow = Self.clamp(row + dy, to: 0, lastRow)

        let newIndex = newRow * columns + newCol
        index = min(newIndex, count - 1)
    }

    /// Set the number of items, clamping the current index if needed.
    public mutating func setCount(_ n: Int) {
        count = n
        index = Self.clamp(index, to: 0, max(0, count - 1))
    }

    /// Select a specific index, clamping it to valid range.
    public mutating func select(_ i: Int) {
        index = Self.clamp(i, to: 0, max(0, count - 1))
    }

    /// Reset selection to index 0.
    public mutating func resetSelection() {
        index = 0
    }

    // MARK: - Private Helpers

    private static func clamp(_ value: Int, to min: Int, _ max: Int) -> Int {
        guard min <= max else { return min }
        return value < min ? min : (value > max ? max : value)
    }
}

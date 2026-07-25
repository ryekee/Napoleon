import Testing
@testable import NapoleonCore

@Suite struct SelectionModelTests {
    @Test func nextWrapsAround() {
        var s = SelectionModel(count: 3, initial: 2)
        s.next()
        #expect(s.index == 0)
    }

    @Test func previousWrapsAround() {
        var s = SelectionModel(count: 3, initial: 0)
        s.previous()
        #expect(s.index == 2)
    }

    @Test func initClampsInitial() {
        #expect(SelectionModel(count: 1, initial: 1).index == 0)
        #expect(SelectionModel(count: 0, initial: 1).index == 0)
    }

    @Test func setCountClampsIndex() {
        var s = SelectionModel(count: 5, initial: 4)
        s.setCount(2)
        #expect(s.index == 1)
        s.setCount(0)
        #expect(s.index == 0)
    }

    @Test func resetSelectionGoesToZero() {
        var s = SelectionModel(count: 5, initial: 3)
        s.resetSelection()
        #expect(s.index == 0)
    }

    @Test func moveInGridClampsAtEdges() {
        var s = SelectionModel(count: 6, initial: 0)
        s.moveInGrid(dx: 1, dy: 0, columns: 3)
        #expect(s.index == 1)
        s.moveInGrid(dx: 0, dy: 1, columns: 3)
        #expect(s.index == 4)
        s.moveInGrid(dx: 0, dy: 1, columns: 3)
        #expect(s.index == 4)   // 已在末行，钳制
    }

    @Test func moveInGridNegativeDirection() {
        var horizontal = SelectionModel(count: 6, initial: 4)
        horizontal.moveInGrid(dx: -1, dy: 0, columns: 3)
        #expect(horizontal.index == 3)

        var vertical = SelectionModel(count: 6, initial: 4)
        vertical.moveInGrid(dx: 0, dy: -1, columns: 3)
        #expect(vertical.index == 1)
    }

    @Test func moveInGridClampsToPartialLastRow() {
        var s = SelectionModel(count: 5, initial: 2)
        s.moveInGrid(dx: 0, dy: 1, columns: 3)
        #expect(s.index == 4)   // 末行只有 index 3、4，不应跳到不存在的 5
    }

    @Test func nextAndPreviousAreNoOpsOnEmptySelection() {
        var s = SelectionModel(count: 0)
        s.next()
        #expect(s.index == 0)
        s.previous()
        #expect(s.index == 0)
    }
}

import Testing
import MokuseiPluginAPI
import MokuseiPluginUI

@Suite struct ThreadCardExtensionLayoutTests {
    private let git = HarnessGitStatus(id: "worktree", root: "/workspace/repo", branch: "main",
        head: nil, upstream: nil, ahead: nil, behind: nil, changed: 1, staged: 0,
        unstaged: 1, untracked: 0, conflicts: 0, additions: 1, deletions: 0, error: nil)

    private func placements(_ presentation: ThreadCardPresentation) throws -> [ThreadCardExtensionKind: ThreadCardExtensionPlacement] {
        guard case .standard(_, _, let placements, _) = presentation.composition else {
            throw ThreadCardComposerError.noCompleteRectangle
        }
        return Dictionary(uniqueKeysWithValues: placements.map { ($0.kind, $0) })
    }

    @Test(arguments: [2, 3, 8], [false, true])
    func newExtensionFillsLowerLeftWithoutMovingTodo(columns: Int, permission: Bool) throws {
        let todo: ThreadCardExtensionProjection = .todo(steps: [.init(step: "Read Note", status: .inProgress)])
        let addedExtension: ThreadCardExtensionProjection = permission
            ? .intervention(.init(id: "permission", title: "Allow tool", actions: [.init(id: "yes", label: "Yes")]))
            : .derived(rows: [.init(id: "child", label: "Collaborating Agent: wait", status: .running, kind: .agent)])
        let context = ThreadCardLayoutContext(availableCols: columns)
        let before = try composeThreadCard(.standard(extensions: [todo]), git: git, layoutContext: context)
        let after = try composeThreadCard(.standard(extensions: [todo, addedExtension]), git: git, layoutContext: context)
        let updated = try composeThreadCard(.standard(extensions: [
            .todo(steps: [.init(step: "Read Note", status: .completed)]),
            permission ? .intervention(.init(id: "next-permission", title: "Allow another tool", actions: [.init(id: "no", label: "No")]))
                : .derived(rows: [.init(id: "another-child", label: "Done", status: .completed, kind: .agent)])
        ]), git: git, layoutContext: context)
        let removed = try composeThreadCard(.standard(extensions: [todo]), git: git, layoutContext: context)

        let original = try placements(before)
        let added = try placements(after)
        #expect(before.size == ThreadCardSize(cols: 2, rows: 2))
        #expect(after.size == before.size)
        #expect(original[.todo]?.col == 1 && original[.todo]?.row == 0)
        #expect(original[.git]?.col == 1 && original[.git]?.row == 1)
        #expect(added[.todo] == original[.todo])
        #expect(added[.git] == original[.git])
        #expect(added[addedExtension.kind]?.col == 0 && added[addedExtension.kind]?.row == 1)
        #expect(try placements(updated) == added)
        #expect(try placements(removed) == original)
        #expect(updated.key == after.key)
        #expect(removed.key == before.key)

        // Host injection and a reordered projection must choose the same cells.
        let reordered = try composeThreadCard(.standard(extensions: [.git(git), addedExtension, todo]), layoutContext: context)
        #expect(reordered.key == after.key)
        #expect(try placements(reordered) == added)
        let readded = try composeThreadCard(.standard(extensions: [addedExtension, todo]), git: git, layoutContext: context)
        #expect(readded.key == after.key)
    }

    @Test(arguments: [2, 3])
    func planAnchorDoesNotDependOnGitVisibility(columns: Int) throws {
        let todo: ThreadCardExtensionProjection = .todo(steps: [.init(step: "Review", status: .pending)])
        let permission: ThreadCardExtensionProjection = .intervention(.init(id: "ask", title: "Permission",
            actions: [.init(id: "yes", label: "Yes")]))
        let context = ThreadCardLayoutContext(availableCols: columns)
        let before = try composeThreadCard(.standard(extensions: [todo]), layoutContext: context)
        let after = try composeThreadCard(.standard(extensions: [permission, todo]), layoutContext: context)
        let removed = try composeThreadCard(.standard(extensions: [todo]), layoutContext: context)
        #expect(try placements(after)[.todo] == placements(before)[.todo])
        #expect(try placements(after)[.intervention]?.row == 1)
        #expect(removed == before)
    }

    @Test(arguments: [1, 2, 3])
    func tallQuestionStillHonorsSizeAndViewportContracts(columns: Int) throws {
        let todo: ThreadCardExtensionProjection = .todo(steps: [.init(step: "Review", status: .pending)])
        let question: ThreadCardExtensionProjection = .intervention(.init(id: "ask", title: "Choose",
            actions: [], questions: [.init(id: "choice", prompt: "Which option?")]))
        let context = ThreadCardLayoutContext(availableCols: columns)
        let before = try composeThreadCard(.standard(extensions: [todo]), git: git, layoutContext: context)
        let after = try composeThreadCard(.standard(extensions: [todo, question]), git: git, layoutContext: context)
        let added = try placements(after)
        #expect(after.size.cols <= columns)
        #expect(added[.intervention]?.selectedSize == ThreadCardSize(cols: 1, rows: 2))
        #expect(added[.todo]?.selectedSize == ThreadCardSize(cols: 1, rows: 1))
        #expect(added[.git]?.selectedSize == ThreadCardSize(cols: 1, rows: 1))
        let removed = try composeThreadCard(.standard(extensions: [todo]), git: git, layoutContext: context)
        #expect(removed == before)
    }
}

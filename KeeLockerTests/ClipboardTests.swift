import AppKit
import XCTest
@testable import KeeLocker

@MainActor
final class ClipboardTests: XCTestCase {
    func testConfirmedTerminationClearsPasswordsCodesAndProtectedFields() async {
        let fixture = SyntheticClipboard()
        defer { fixture.pasteboard.releaseGlobally() }

        for value in ["synthetic-password", "123456", "synthetic-protected-field"] {
            XCTAssertTrue(fixture.owner.copy(value))
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), value)
            fixture.owner.clearOnTermination()
            XCTAssertNil(fixture.pasteboard.string(forType: .string))
        }
    }

    func testNormalCleanupRemainsScheduledUntilTerminationIsConfirmed() async {
        let fixture = SyntheticClipboard()
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.owner.copy("synthetic-password")
        XCTAssertEqual(fixture.clock.delays, [30])

        // A cancelled Quit never calls clearOnTermination.
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "synthetic-password")
        fixture.clock.run(0)
        XCTAssertNil(fixture.pasteboard.string(forType: .string))
    }

    func testLaterExternalValueSurvivesBothTimerAndTerminationEvenWhenIdentical() async {
        let fixture = SyntheticClipboard()
        defer { fixture.pasteboard.releaseGlobally() }
        for externalValue in ["synthetic-external-value", "synthetic-password"] {
            fixture.owner.copy("synthetic-password")
            fixture.pasteboard.clearContents()
            XCTAssertTrue(fixture.pasteboard.setString(externalValue, forType: .string))
            fixture.owner.clearOnTermination()
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), externalValue)
            fixture.clock.run(fixture.clock.delays.count - 1)
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), externalValue)
        }
    }

    func testOlderTimerCannotClearANewerCopyFromAnotherDetailView() async {
        let fixture = SyntheticClipboard()
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.owner.copy("synthetic-first-password")
        fixture.owner.copy("synthetic-second-password")
        fixture.clock.run(0)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "synthetic-second-password")
        fixture.clock.run(1)
        XCTAssertNil(fixture.pasteboard.string(forType: .string))
    }

    func testDisabledClearingPreservesCopyOnQuitAndDoesNotScheduleATimer() async {
        let fixture = SyntheticClipboard()
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.policy.enabled = false
        fixture.owner.copy("synthetic-opt-out-password")
        XCTAssertTrue(fixture.clock.delays.isEmpty)
        fixture.owner.clearOnTermination()
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "synthetic-opt-out-password")
        fixture.policy.enabled = true
        fixture.owner.clearOnTermination()
        XCTAssertNil(fixture.pasteboard.string(forType: .string))
    }

    func testDisablingClearingAfterCopyIsRespectedByTimerAndQuit() async {
        let fixture = SyntheticClipboard()
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.owner.copy("synthetic-password")
        fixture.policy.enabled = false
        fixture.clock.run(0)
        fixture.owner.clearOnTermination()
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "synthetic-password")
        fixture.policy.enabled = true
        fixture.owner.clearOnTermination()
        XCTAssertNil(fixture.pasteboard.string(forType: .string))
    }

    func testTerminationWithoutOwnershipPreservesExistingClipboard() async {
        let fixture = SyntheticClipboard()
        defer { fixture.pasteboard.releaseGlobally() }
        XCTAssertTrue(fixture.pasteboard.setString("synthetic-external-value", forType: .string))
        fixture.owner.clearOnTermination()
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "synthetic-external-value")
    }

    func testEmptyCopyDoesNotReplaceOwnedValueOrItsTimer() async {
        let fixture = SyntheticClipboard()
        defer { fixture.pasteboard.releaseGlobally() }
        fixture.owner.copy("synthetic-password")
        XCTAssertFalse(fixture.owner.copy(""))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "synthetic-password")
        XCTAssertEqual(fixture.clock.delays, [30])
        fixture.clock.run(0)
        XCTAssertNil(fixture.pasteboard.string(forType: .string))
    }
}

final class ItemEditingDraftTests: XCTestCase {
    func testTagTypingStaysVerbatimUntilSaveAndPreservesFavorites() {
        var item = VaultItem.empty
        item.tags = ["original"]
        item.isFavorite = true
        var draft = ItemEditingDraft(item)

        for text in ["work;", "work; ", "work;  p", "work;  personal ; ;\n travel \t;"] {
            draft.tagsText = text
            XCTAssertEqual(draft.tagsText, text)
            XCTAssertEqual(draft.item.tags, ["original"], "Typing must not rewrite the entry")
        }
        let saved = draft.savedItem
        XCTAssertEqual(saved.tags, ["work", "personal", "travel"])
        XCTAssertTrue(saved.isFavorite)
        XCTAssertEqual(saved.id, item.id)
        XCTAssertEqual(draft.tagsText, "work;  personal ; ;\n travel \t;", "Save preparation must not rewrite input on a failed save")
    }

    func testCancelAndSwitchReplaceTheEntireDraft() {
        var first = VaultItem.empty
        first.tags = ["first", "entry"]
        var draft = ItemEditingDraft(first)
        XCTAssertEqual(draft.tagsText, "first; entry")
        draft.tagsText = "unfinished; "
        draft.item.isFavorite = true

        draft = ItemEditingDraft()
        XCTAssertTrue(draft.tagsText.isEmpty)
        XCTAssertTrue(draft.item.tags.isEmpty)
        XCTAssertFalse(draft.item.isFavorite)
        XCTAssertEqual(first.tags, ["first", "entry"])

        var second = VaultItem.empty
        second.tags = ["second"]
        draft = ItemEditingDraft(second)
        XCTAssertEqual(draft.tagsText, "second")
        XCTAssertEqual(draft.savedItem.tags, ["second"])
        XCTAssertEqual(draft.savedItem.id, second.id)
    }

    func testNewFavoriteDraftCanSaveWithoutTags() {
        var item = VaultItem.empty
        item.isFavorite = true
        var draft = ItemEditingDraft(item)
        draft.tagsText = " ; \n ; "
        XCTAssertTrue(draft.savedItem.tags.isEmpty)
        XCTAssertTrue(draft.savedItem.isFavorite)
    }
}

@MainActor
private final class SyntheticClipboard {
    let pasteboard = NSPasteboard(name: .init("KeeLockerTests.Clipboard.\(UUID().uuidString)"))
    let policy = SyntheticClipboardPolicy()
    let clock = SyntheticClipboardClock()
    let owner: ClipboardOwner

    init() {
        let policy = policy
        let clock = clock
        owner = ClipboardOwner(pasteboard: pasteboard, shouldClear: { policy.enabled },
                               scheduleCleanup: { delay, cleanup in clock.schedule(delay, cleanup) })
    }
}

@MainActor
private final class SyntheticClipboardPolicy {
    var enabled = true
}

@MainActor
private final class SyntheticClipboardClock {
    private(set) var delays: [TimeInterval] = []
    private var cleanups: [@MainActor () -> Void] = []

    func schedule(_ delay: TimeInterval, _ cleanup: @escaping @MainActor () -> Void) {
        delays.append(delay)
        cleanups.append(cleanup)
    }

    func run(_ index: Int) { cleanups[index]() }
}

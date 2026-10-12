import XCTest
@testable import Atelier

@MainActor final class AtelierTests: XCTestCase {
    private func makeStore() throws -> (Store, Repository) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = try Repository(directory: directory)
        return (Store(repository: repository), repository)
    }
    private func draft() -> Draft {
        var draft = Draft(); draft.name = "Олена"; draft.phone = "0501234567"
        draft.items = [DraftItem(name: "Штани", repairs: [Repair(title: "Підшити", price: 300)]), DraftItem(name: "Куртка", repairs: [Repair(title: "Замінити блискавку", price: 500)])]
        draft.advance = 200
        return draft
    }
    func testAtomicCreationPersistenceAndDuplicateProtection() throws {
        let (store, repository) = try makeStore()
        let draft = draft(); store.saveDraft(draft)
        let id = try XCTUnwrap(store.commit(draft))
        XCTAssertNil(store.commit(draft))
        let loaded = try repository.load()
        XCTAssertEqual(loaded.orders.count, 1)
        XCTAssertEqual(loaded.orders[0].id, id)
        XCTAssertEqual(loaded.orders[0].items.count, 2)
        XCTAssertEqual(loaded.debt(loaded.orders[0]), 600)
        XCTAssertTrue(loaded.drafts.isEmpty)
    }
    func testTrashNeverReusesNumberOrErasesPayment() throws {
        let (store, _) = try makeStore()
        let first = draft(); store.saveDraft(first)
        _ = try XCTUnwrap(store.commit(first))
        store.change { $0.orders[0].deletedAt = Date() }
        let second = draft(); store.saveDraft(second)
        _ = try XCTUnwrap(store.commit(second))
        XCTAssertEqual(store.data.orders.map(\.number), [1, 2])
        XCTAssertEqual(store.data.payments.reduce(0) { $0 + $1.amount }, 400)
        XCTAssertEqual(store.data.clients.count, 1)
    }
    func testPartialIssueWithDebtAndSafeUndo() throws {
        let (store, _) = try makeStore(); let draft = draft(); store.saveDraft(draft)
        let id = try XCTUnwrap(store.commit(draft))
        let ids = Set(store.data.orders[0].items.map(\.id))
        store.setStatus(ids, to: .ready); store.undoStatus()
        XCTAssertTrue(store.data.orders[0].items.allSatisfy { $0.status == .accepted })
        store.setStatus(ids, to: .ready)
        store.issue(id, items: [store.data.orders[0].items[0].id])
        XCTAssertEqual(store.data.orders[0].items[0].status, .issued)
        XCTAssertEqual(store.data.orders[0].items[1].status, .ready)
        XCTAssertNotNil(store.data.orders[0].items[0].issuedAt)
        XCTAssertEqual(store.data.debt(store.data.orders[0]), 600)
        XCTAssertFalse(store.canUndo)
        store.setStatus(ids, to: .working)
        XCTAssertEqual(store.data.orders[0].items[0].status, .issued)
    }
    func testFailedMutationDoesNotChangePersistedState() throws {
        let (store, repository) = try makeStore()
        XCTAssertFalse(store.change { $0.nextNumber = -1 })
        XCTAssertEqual(store.data.nextNumber, 1)
        XCTAssertEqual(try repository.load().nextNumber, 1)
    }
    func testEncryptedBackupRoundTripAndWrongPassword() throws {
        let (store, _) = try makeStore(); let draft = draft(); store.saveDraft(draft)
        _ = try XCTUnwrap(store.commit(draft))
        let data = try Backup.encrypt(store.data, password: "мій-пароль-123")
        let restored = try Backup.decrypt(data, password: "мій-пароль-123")
        XCTAssertEqual(restored.orders[0].id, store.data.orders[0].id)
        XCTAssertEqual(restored.orders[0].items.map(\.id), store.data.orders[0].items.map(\.id))
        XCTAssertEqual(restored.payments[0].amount, 200)
        XCTAssertEqual(restored.nextNumber, 2)
        XCTAssertThrowsError(try Backup.decrypt(data, password: "інший-пароль-123"))
        var corrupt = data; corrupt[corrupt.startIndex] = 0
        XCTAssertThrowsError(try Backup.decrypt(corrupt, password: "мій-пароль-123"))
    }
}

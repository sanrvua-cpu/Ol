import SwiftUI

@MainActor final class Store: ObservableObject {
    @Published private(set) var data = Database()
    @Published var error: String?
    @Published private(set) var available = false
    private var repository: Repository?
    private var undo: [(UUID, ItemStatus, Date?, ItemStatus, Date?)] = []
    init(repository supplied: Repository? = nil) {
        do { let repo = try supplied ?? Repository(); data = try repo.load(); repository = repo; available = true }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult func change(_ action: (inout Database) throws -> Void) -> Bool {
        guard let repository else { error = "База недоступна. Перезапустіть застосунок."; return false }
        do {
            var next = data
            try action(&next)
            try repository.save(next)
            data = next
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func saveDraft(_ draft: Draft) {
        change { db in
            var draft = draft; draft.updated = Date()
            if let i = db.drafts.firstIndex(where: { $0.id == draft.id }) { db.drafts[i] = draft }
            else { db.drafts.append(draft) }
        }
    }
    func commit(_ draft: Draft, quick: Bool = false) -> UUID? {
        var orderID: UUID?
        let success = change { db in
            guard db.drafts.contains(where: { $0.id == draft.id }) else { throw AppError.message("Ця чернетка вже збережена або видалена") }
            guard draft.advance >= 0, draft.advance <= 10_000_000,
                  draft.items.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.repairs.isEmpty && $0.repairs.allSatisfy { (quick || !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && $0.price >= 0 } }) else { throw AppError.message("Вкажіть назву речі й роботи та коректні суми") }
            var clientID = draft.clientID
            if clientID == nil && !draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
                let phone = draft.phone.filter(\.isNumber)
                if !phone.isEmpty, let existing = db.clients.first(where: { $0.phone.filter(\.isNumber) == phone }) { clientID = existing.id }
                else { let client = Client(name: draft.name.trimmingCharacters(in: .whitespaces), phone: draft.phone); db.clients.append(client); clientID = client.id }
            }
            guard quick || clientID != nil else { throw AppError.message("Вкажіть ім’я клієнта") }
            let items = draft.items.enumerated().map { index, entry in
                Garment(id: entry.id, sequence: index + 1, name: entry.name, repairs: entry.repairs.map { repair in var result = repair; if quick && result.title.isEmpty { result.title = entry.name }; return result }, due: entry.due, urgent: entry.urgent,
                        status: quick ? .issued : .accepted, readyAt: quick ? Date() : nil, issuedAt: quick ? Date() : nil)
            }
            let total = items.reduce(0) { $0 + $1.total }
            guard !quick || draft.advance >= total || clientID != nil || !draft.note.isEmpty else { throw AppError.message("Для боргу вкажіть клієнта або примітку") }
            let order = Order(number: db.nextNumber, clientID: clientID, items: items, quick: quick, note: draft.note)
            db.nextNumber += 1; db.orders.append(order)
            if draft.advance > 0 { db.payments.append(Payment(orderID: order.id, amount: draft.advance, method: draft.method)) }
            db.drafts.removeAll { $0.id == draft.id }
            orderID = order.id
        }
        return success ? orderID : nil
    }
    func setStatus(_ ids: Set<UUID>, to status: ItemStatus) {
        var record: [(UUID, ItemStatus, Date?, ItemStatus, Date?)] = []
        let success = change { db in
            for oi in db.orders.indices where db.orders[oi].deletedAt == nil {
                for ii in db.orders[oi].items.indices {
                    let item = db.orders[oi].items[ii]
                    guard ids.contains(item.id), item.status != .issued, status != .issued, item.status != status else { continue }
                    let ready: Date? = status == .ready ? Date() : nil
                    record.append((item.id, item.status, item.readyAt, status, ready))
                    db.orders[oi].items[ii].status = status; db.orders[oi].items[ii].readyAt = ready
                }
            }
        }
        if success { undo = record }
    }
    var canUndo: Bool { !undo.isEmpty }
    func undoStatus() {
        let success = change { db in
            for entry in undo {
                guard let oi = db.orders.firstIndex(where: { $0.deletedAt == nil && $0.items.contains { $0.id == entry.0 } }),
                      let ii = db.orders[oi].items.firstIndex(where: { $0.id == entry.0 }),
                      db.orders[oi].items[ii].status == entry.3, db.orders[oi].items[ii].readyAt == entry.4 else {
                    throw AppError.message("Речі вже змінилися. Скасування недоступне.")
                }
                db.orders[oi].items[ii].status = entry.1; db.orders[oi].items[ii].readyAt = entry.2
            }
        }
        if success { undo = [] }
    }
    func issue(_ orderID: UUID, items: Set<UUID>) {
        if change({ db in
            guard let index = db.orders.firstIndex(where: { $0.id == orderID && $0.deletedAt == nil }) else { return }
            for i in db.orders[index].items.indices where items.contains(db.orders[index].items[i].id) && db.orders[index].items[i].status != .issued {
                db.orders[index].items[i].status = .issued; db.orders[index].items[i].issuedAt = Date()
            }
        }) { undo = [] }
    }
    func replace(with incoming: Database) -> Bool {
        guard let repository else { return false }
        do {
            try incoming.validate()
            // Захисна копія до заміни; лежить у захищеному локальному контейнері.
            let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let url = folder.appendingPathComponent("before-restore-\(UUID().uuidString).json")
            try JSONEncoder().encode(data).write(to: url, options: [.atomic, .completeFileProtection])
            try repository.save(incoming); data = incoming; undo = []; return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

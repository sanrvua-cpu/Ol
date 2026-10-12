import Foundation

enum ItemStatus: String, Codable, CaseIterable, Identifiable {
    case accepted = "Прийнято", working = "У роботі", ready = "Готове", issued = "Видано"
    var id: String { rawValue }
    var unfinished: Bool { self == .accepted || self == .working }
}
enum PaymentMethod: String, Codable, CaseIterable, Identifiable {
    case cash = "Готівка", bank = "Переказ"
    var id: String { rawValue }
}
struct Client: Codable, Identifiable {
    var id = UUID()
    var name: String
    var phone: String
    var note = ""
}
struct Repair: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var price = 0
}
struct Garment: Codable, Identifiable {
    var id = UUID()
    var sequence: Int
    var name: String
    var repairs: [Repair]
    var due: Date
    var urgent = false
    var status: ItemStatus = .accepted
    var readyAt: Date?
    var issuedAt: Date?
    var total: Int { repairs.reduce(0) { $0 + $1.price } }
}
struct Order: Codable, Identifiable {
    var id = UUID()
    var number: Int
    var clientID: UUID?
    var created = Date()
    var items: [Garment]
    var quick = false
    var note = ""
    var deletedAt: Date?
    var total: Int { items.reduce(0) { $0 + $1.total } }
    func label(_ item: Garment) -> String { "\(number)-\(String(format: "%02d", item.sequence))" }
}
struct PaymentRevision: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var oldAmount: Int
    var oldMethod: PaymentMethod
    var oldDate: Date
}
struct Payment: Codable, Identifiable {
    var id = UUID()
    var orderID: UUID
    // Від'ємне значення — фактичне повернення клієнту.
    var amount: Int
    var method: PaymentMethod
    var date = Date()
    var revisions: [PaymentRevision] = []
}
struct Expense: Codable, Identifiable {
    var id = UUID()
    var amount: Int
    var category: String
    var date = Date()
}
struct Service: Codable, Identifiable {
    var id = UUID()
    var category = "Ремонт"
    var title: String
    var price: Int
    var favorite = false
}
struct DraftItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var repairs = [Repair()]
    var due = Date()
    var urgent = false
}
struct Draft: Codable, Identifiable, Equatable {
    var id = UUID()
    var quick = false
    var clientID: UUID?
    var name = ""
    var phone = ""
    var items = [DraftItem()]
    var advance = 0
    var method: PaymentMethod = .cash
    var note = ""
    var updated = Date()
}
struct Settings: Codable {
    var lockEnabled = false
    var backupDays = 3
    var lastBackup: Date?
    var workingDays = [2, 3, 4, 5, 6]
}
struct Database: Codable {
    var formatVersion = 1
    var nextNumber = 1
    var clients: [Client] = []
    var orders: [Order] = []
    var payments: [Payment] = []
    var expenses: [Expense] = []
    var services: [Service] = []
    var drafts: [Draft] = []
    var settings = Settings()
    func paid(_ order: Order) -> Int { payments.filter { $0.orderID == order.id }.reduce(0) { $0 + $1.amount } }
    func debt(_ order: Order) -> Int { max(0, order.total - paid(order)) }
    func clientName(_ order: Order) -> String { clients.first { $0.id == order.clientID }?.name ?? "Без клієнта" }
    var active: [Order] { orders.filter { $0.deletedAt == nil } }
    func validate() throws {
        guard formatVersion == 1, nextNumber > (orders.map(\.number).max() ?? 0),
              Set(orders.map(\.id)).count == orders.count,
              Set(orders.map(\.number)).count == orders.count,
              Set(clients.map(\.id)).count == clients.count,
              Set(payments.map(\.id)).count == payments.count else { throw AppError.message("Некоректна структура даних") }
        let clientIDs = Set(clients.map(\.id)), orderIDs = Set(orders.map(\.id))
        let items = orders.flatMap(\.items)
        guard Set(items.map(\.id)).count == items.count,
              orders.allSatisfy({ $0.number > 0 && ($0.clientID == nil || clientIDs.contains($0.clientID!)) && !$0.items.isEmpty && Set($0.items.map(\.sequence)).count == $0.items.count }),
              items.allSatisfy({ $0.sequence > 0 && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && !$0.repairs.isEmpty && $0.repairs.allSatisfy { $0.price >= 0 && $0.price <= 10_000_000 } }),
              payments.allSatisfy({ orderIDs.contains($0.orderID) && $0.amount >= -10_000_000 && $0.amount <= 10_000_000 }),
              expenses.allSatisfy({ $0.amount > 0 && $0.amount <= 10_000_000 }) else { throw AppError.message("Некоректні суми або зв’язки записів") }
    }
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
extension Int { var hryvnia: String { "\(self) грн" } }

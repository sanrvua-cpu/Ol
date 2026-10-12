import SwiftUI

struct OrderEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var draft = Draft()
    var quick = false
    @State private var savedID: UUID?
    @State private var clientSearch = ""
    @State private var serviceItem: UUID?
    @State private var initialized = false
    var body: some View {
        Form {
            Section(quick ? "Клієнт — необов’язково" : "Клієнт") {
                TextField("Знайти клієнта", text: $clientSearch)
                if !clientSearch.isEmpty {
                    ForEach(store.data.clients.filter { "\($0.name) \($0.phone)".localizedCaseInsensitiveContains(clientSearch) }.prefix(5)) { client in
                        Button("\(client.name) · \(client.phone)") { draft.clientID = client.id; draft.name = client.name; draft.phone = client.phone; clientSearch = "" }
                    }
                }
                TextField("Ім’я", text: $draft.name).disabled(draft.clientID != nil)
                TextField("Телефон", text: $draft.phone).keyboardType(.phonePad).disabled(draft.clientID != nil)
                if draft.clientID != nil { Button("Інший клієнт") { draft.clientID = nil; draft.name = ""; draft.phone = "" } }
            }
            ForEach($draft.items) { $item in
                Section(quick ? "Робота" : "Річ") {
                    TextField(quick ? "Назва роботи / речі" : "Назва одягу", text: $item.name)
                    ForEach($item.repairs) { $repair in
                        if !quick { TextField("Що зробити", text: $repair.title) }
                        MoneyField(title: "Ціна, грн", amount: $repair.price)
                    }
                    Button("Вибрати з прайсу") { serviceItem = item.id }
                    if !quick { Button("Додати роботу") { item.repairs.append(Repair()) } }
                    if item.repairs.count > 1 { Button("Прибрати останню роботу", role: .destructive) { item.repairs.removeLast() } }
                    if !quick {
                        DatePicker("Готовність", selection: $item.due, displayedComponents: .date)
                        Toggle("Терміново", isOn: $item.urgent)
                    }
                    if draft.items.count > 1 { Button("Прибрати річ", role: .destructive) { draft.items.removeAll { $0.id == item.id } } }
                }
            }
            if !quick { Button("Додати ще одну річ") { var item = DraftItem(); item.due = draft.items.first?.due ?? Date(); draft.items.append(item) } }
            Section("Оплата") {
                Text("Загалом: \(total.hryvnia)").font(.headline)
                MoneyField(title: quick ? "Отримано, грн" : "Аванс, грн", amount: $draft.advance)
                Picker("Спосіб", selection: $draft.method) { ForEach(PaymentMethod.allCases) { Text($0.rawValue).tag($0) } }
                if quick { Button("Отримано всю суму") { draft.advance = total } }
            }
            Section { TextField("Примітка / домовленість", text: $draft.note, axis: .vertical) }
            Button("Зберегти замовлення") { savedID = store.commit(draft, quick: quick) }.font(.headline).disabled(savedID != nil)
            Text("Введені дані зберігаються як чернетка.").font(.footnote).foregroundStyle(.secondary)
            Text("Нові роботи автоматично додаються до прайсу з ціною після збереження. Ціну вже відомої роботи можна змінити для цього замовлення.").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle(quick ? "Швидкий ремонт" : "Нове замовлення")
            .onAppear { if !initialized { initialized = true; draft.quick = quick; store.saveDraft(draft) } }
            .onChange(of: draftEncoded) { _, _ in if initialized && savedID == nil { store.saveDraft(draft) } }
            .onChange(of: total) { old, new in if quick && draft.advance == old { draft.advance = new } }
            .sheet(isPresented: Binding(get: { serviceItem != nil }, set: { if !$0 { serviceItem = nil } })) {
                NavigationStack { ServicePicker { service in
                    if let index = draft.items.firstIndex(where: { $0.id == serviceItem }) {
                        let repair = Repair(title: service.title, price: service.price)
                        if quick { draft.items[index].name = service.title }
                        if draft.items[index].repairs.count == 1 && draft.items[index].repairs[0].title.isEmpty { draft.items[index].repairs = [repair] }
                        else { draft.items[index].repairs.append(repair) }
                    }
                    serviceItem = nil
                } }
            }
            .navigationDestination(isPresented: Binding(get: { savedID != nil }, set: { if !$0 { dismiss() } })) { if let id = savedID { OrderDetail(id: id) } }
    }
    private var draftEncoded: Data { (try? JSONEncoder().encode(draft)) ?? Data() }
    private var total: Int { draft.items.flatMap(\.repairs).reduce(0) { $0 + $1.price } }
}
struct MoneyField: View {
    let title: String
    @Binding var amount: Int
    var body: some View {
        HStack { Text(title); Spacer(); TextField("0", text: Binding(get: { amount == 0 ? "" : String(amount) }, set: { value in
            let digits = String(value.filter(\.isNumber).prefix(8)); amount = min(Int(digits) ?? 0, 10_000_000)
        })).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 140) }
    }
}
struct DraftsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        List {
            ForEach(store.data.drafts.sorted { $0.updated > $1.updated }) { draft in
                NavigationLink { OrderEditor(draft: draft, quick: draft.quick) } label: { VStack(alignment: .leading) { Text(draft.name.isEmpty ? "Нове замовлення" : draft.name); Text(draft.updated.formatted()).font(.caption) } }
                    .swipeActions { Button("Видалити", role: .destructive) { store.change { $0.drafts.removeAll { $0.id == draft.id } } } }
            }
        }.navigationTitle("Чернетки")
    }
}
struct OrderDetail: View {
    @EnvironmentObject var store: Store
    let id: UUID
    @State private var selected: Set<UUID> = []
    @State private var paymentOpen = false
    @State private var confirmIssue = false
    @State private var confirmDelete = false
    var body: some View {
        if let order = store.data.orders.first(where: { $0.id == id }) {
            List {
                Section("Замовлення № \(order.number)") {
                    Text(store.data.clientName(order)).font(.headline)
                    Text("Вартість: \(order.total.hryvnia)")
                    Text("Сплачено: \(store.data.paid(order).hryvnia)")
                    Text("Залишилося: \(store.data.debt(order).hryvnia)").foregroundStyle(store.data.debt(order) > 0 ? .orange : .primary)
                    if store.data.paid(order) > order.total { Text("Переплата: \((store.data.paid(order) - order.total).hryvnia)") }
                    if !order.note.isEmpty { Text(order.note) }
                    Button("Записати оплату / повернення") { paymentOpen = true }
                }
                Section("Речі — номери для ручних бірок") {
                    ForEach(order.items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                if item.status != .issued { Button { if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) } } label: { Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle") }.buttonStyle(.borderless) }
                                Text("\(order.label(item)) · \(item.name)").font(.headline)
                                if item.urgent { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                            }
                            ForEach(item.repairs) { repair in Text("\(repair.title) — \(repair.price.hryvnia)").font(.subheadline) }
                            if item.status == .issued { Text("Видано: \(item.issuedAt?.formatted() ?? "")").foregroundStyle(.secondary) }
                            else {
                                Picker("Стан", selection: Binding(get: { item.status }, set: { store.setStatus([item.id], to: $0) })) { ForEach(ItemStatus.allCases.filter { $0 != .issued }) { Text($0.rawValue).tag($0) } }
                                DatePicker("Готовність", selection: Binding(get: { item.due }, set: { date in store.change { db in if let oi = db.orders.firstIndex(where: { $0.id == id }), let ii = db.orders[oi].items.firstIndex(where: { $0.id == item.id }) { db.orders[oi].items[ii].due = date } } }), displayedComponents: .date)
                            }
                        }.padding(.vertical, 4)
                    }
                }
                if !selected.isEmpty {
                    Section("Вибрано: \(selected.count)") {
                        Button("У роботі") { store.setStatus(selected, to: .working) }
                        Button("Готове") { store.setStatus(selected, to: .ready) }
                        Button("Видати вибрані") { confirmIssue = true }
                    }
                }
                if store.canUndo { Button("Скасувати останню зміну станів") { store.undoStatus() } }
                Section("Платежі") {
                    ForEach(store.data.payments.filter { $0.orderID == id }.sorted { $0.date > $1.date }) { payment in
                        NavigationLink { PaymentEditor(orderID: id, existing: payment) } label: { VStack(alignment: .leading) { Text("\(payment.amount.hryvnia) · \(payment.method.rawValue)"); Text(payment.date.formatted()).font(.caption) } }
                    }
                }
                if order.deletedAt == nil { Button("Перемістити до кошика", role: .destructive) { confirmDelete = true } }
            }.navigationTitle("№ \(order.number)")
                .sheet(isPresented: $paymentOpen) { NavigationStack { PaymentEditor(orderID: id) } }
                .alert("Видати \(selected.count) речей?", isPresented: $confirmIssue) {
                    Button("Скасувати", role: .cancel) {}
                    Button("Видати") { store.issue(id, items: selected); selected = [] }
                } message: { Text(store.data.debt(order) > 0 ? "У замовленні залишається борг \(store.data.debt(order).hryvnia). Видача дозволена." : "Буде записано дату й час видачі.") }
                .alert("Перемістити замовлення до кошика?", isPresented: $confirmDelete) { Button("Скасувати", role: .cancel) {}; Button("До кошика", role: .destructive) { store.change { db in if let i = db.orders.firstIndex(where: { $0.id == id }) { db.orders[i].deletedAt = Date() } } } } message: { Text("Платежі залишаться в підсумках. Замовлення можна відновити з меню.") }
        }
    }
}
struct PaymentEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let orderID: UUID
    var existing: Payment?
    @State private var amount = 0
    @State private var method: PaymentMethod = .cash
    @State private var date = Date()
    @State private var refund = false
    @State private var duplicate = false
    @State private var initialized = false
    var body: some View {
        Form {
            Toggle("Повернення клієнту", isOn: $refund)
            MoneyField(title: "Сума, грн", amount: $amount)
            Picker("Спосіб", selection: $method) { ForEach(PaymentMethod.allCases) { Text($0.rawValue).tag($0) } }
            DatePicker("Дата", selection: $date)
            Button("Зберегти") { if similar { duplicate = true } else { save() } }.disabled(amount == 0)
            if let existing, !existing.revisions.isEmpty {
                Section("Історія виправлень") { ForEach(existing.revisions) { revision in Text("\(revision.date.formatted()): раніше \(revision.oldAmount.hryvnia), \(revision.oldMethod.rawValue), \(revision.oldDate.formatted())") } }
            }
        }.navigationTitle(existing == nil ? "Записати оплату" : "Виправити оплату")
            .onAppear {
                guard !initialized else { return }; initialized = true
                if let p = existing { amount = abs(p.amount); refund = p.amount < 0; method = p.method; date = p.date }
                else if let order = store.data.orders.first(where: { $0.id == orderID }) { amount = store.data.debt(order) }
            }
            .alert("Схожа оплата вже записана", isPresented: $duplicate) { Button("Скасувати", role: .cancel) {}; Button("Додати ще одну") { save() } } message: { Text("Збігаються замовлення, сума, спосіб і дата. Це справді окрема оплата?") }
    }
    private var similar: Bool { existing == nil && store.data.payments.contains { $0.orderID == orderID && $0.amount == (refund ? -amount : amount) && $0.method == method && Calendar.current.isDate($0.date, inSameDayAs: date) } }
    private func save() {
        if store.change({ db in
            let signed = refund ? -amount : amount
            if let existing, let index = db.payments.firstIndex(where: { $0.id == existing.id }) {
                let old = db.payments[index]
                db.payments[index].revisions.append(PaymentRevision(oldAmount: old.amount, oldMethod: old.method, oldDate: old.date))
                db.payments[index].amount = signed; db.payments[index].method = method; db.payments[index].date = date
            } else { db.payments.append(Payment(orderID: orderID, amount: signed, method: method, date: date)) }
        }) { dismiss() }
    }
}

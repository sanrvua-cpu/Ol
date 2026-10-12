import SwiftUI

struct SummaryView: View {
    @EnvironmentObject var store: Store
    @State private var period = "День"
    @State private var anchor = Date()
    @State private var expenseOpen = false
    private var component: Calendar.Component { switch period { case "Тиждень": return .weekOfYear; case "Місяць": return .month; case "Рік": return .year; default: return .day } }
    private var interval: DateInterval { var calendar = Calendar.current; calendar.firstWeekday = 2; return calendar.dateInterval(of: component, for: anchor)! }
    private func includes(_ date: Date) -> Bool { date >= interval.start && date < interval.end }
    private var payments: [Payment] { store.data.payments.filter { includes($0.date) } }
    private var expenses: [Expense] { store.data.expenses.filter { includes($0.date) } }
    private var received: Int { payments.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount } }
    private var returned: Int { -payments.filter { $0.amount < 0 }.reduce(0) { $0 + $1.amount } }
    private var spent: Int { expenses.reduce(0) { $0 + $1.amount } }
    var body: some View {
        List {
            Section {
                Picker("Період", selection: $period) { ForEach(["День", "Тиждень", "Місяць", "Рік"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                DatePicker("Дата в періоді", selection: $anchor, displayedComponents: .date)
                HStack { Button { shift(-1) } label: { Image(systemName: "chevron.left") }; Spacer(); Text(interval.start.formatted(date: .abbreviated, time: .omitted)); Spacer(); Button { shift(1) } label: { Image(systemName: "chevron.right") } }.buttonStyle(.borderless)
                Text("До \(interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted)) включно").font(.caption).foregroundStyle(.secondary)
            }
            Section("Гроші за період") {
                row("Отримано", received)
                ForEach(PaymentMethod.allCases) { method in row(method.rawValue, payments.filter { $0.method == method && $0.amount > 0 }.reduce(0) { $0 + $1.amount }) }
                row("Повернуто клієнтам", returned)
                row("Витрачено", spent)
                row("Залишилося після витрат", received - returned - spent)
                Text("Це рух записаних грошей за період.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Робота за період") {
                let items = store.data.active.flatMap(\.items)
                LabeledContent("Прийнято речей", value: "\(store.data.active.filter { includes($0.created) }.flatMap(\.items).count)")
                LabeledContent("Завершено ремонтів", value: "\(items.filter { $0.readyAt.map(includes) ?? false }.count)")
                LabeledContent("Видано речей", value: "\(items.filter { $0.issuedAt.map(includes) ?? false }.count)")
            }
            Section("Поточний стан") { NavigationLink { OrdersView(filter: "Борги") } label: { row("Борги зараз", store.data.active.reduce(0) { $0 + store.data.debt($1) }) } }
            Section("Витрати за період") {
                Button("Записати витрату") { expenseOpen = true }
                ForEach(expenses.sorted { $0.date > $1.date }) { expense in
                    NavigationLink { ExpenseEditor(existing: expense) } label: { VStack(alignment: .leading) { Text("\(expense.category) · \(expense.amount.hryvnia)"); Text(expense.date.formatted(date: .abbreviated, time: .omitted)).font(.caption) } }
                }
            }
        }.navigationTitle("Підсумки").sheet(isPresented: $expenseOpen) { NavigationStack { ExpenseEditor() } }
    }
    private func row(_ title: String, _ amount: Int) -> some View { LabeledContent(title, value: amount.hryvnia) }
    private func shift(_ value: Int) { if let date = Calendar.current.date(byAdding: component, value: value, to: anchor) { anchor = date } }
}
struct ExpenseEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var existing: Expense?
    @State private var amount = 0
    @State private var category = "Фурнітура"
    @State private var date = Date()
    var body: some View {
        Form {
            MoneyField(title: "Сума, грн", amount: $amount)
            Picker("Категорія", selection: $category) { ForEach(["Фурнітура", "Оренда", "Комунальні послуги", "Інше"], id: \.self) { Text($0) } }
            DatePicker("Дата", selection: $date, displayedComponents: .date)
            Button("Зберегти") {
                if store.change({ db in
                    if let existing, let index = db.expenses.firstIndex(where: { $0.id == existing.id }) { db.expenses[index].amount = amount; db.expenses[index].category = category; db.expenses[index].date = date }
                    else { db.expenses.append(Expense(amount: amount, category: category, date: date)) }
                }) { dismiss() }
            }.disabled(amount == 0)
        }.navigationTitle("Витрата").onAppear { if let existing { amount = existing.amount; category = existing.category; date = existing.date } }
    }
}
struct MenuView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        List {
            NavigationLink("Прайс і улюблені послуги") { PriceView() }
            NavigationLink("Календар готовності") { ScheduleView() }
            NavigationLink("Чернетки") { DraftsView() }
            NavigationLink("Кошик") { TrashView() }
            NavigationLink("Резервна копія") { BackupView() }
            Section("Захист") {
                Toggle("Face ID або код iPhone", isOn: Binding(get: { store.data.settings.lockEnabled }, set: { value in store.change { $0.settings.lockEnabled = value } }))
                Text("Використовується системний код пристрою. Для захисту встановіть код у налаштуваннях iPhone.").font(.footnote)
            }
            Section("Робочі дні") {
                ForEach(1...7, id: \.self) { day in
                    Toggle(["", "Неділя", "Понеділок", "Вівторок", "Середа", "Четвер", "П’ятниця", "Субота"][day], isOn: Binding(get: { store.data.settings.workingDays.contains(day) }, set: { enabled in store.change { db in db.settings.workingDays.removeAll { $0 == day }; if enabled { db.settings.workingDays.append(day) } } }))
                }
            }
            Section("Ательє 1.0") { Text("Електронний зошит майстра. Суми — цілі гривні. Друк і QR будуть додані окремим оновленням.") }
        }.navigationTitle("Меню")
    }
}
struct PriceView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    var body: some View {
        List {
            ForEach(store.data.services.filter { search.isEmpty || "\($0.title) \($0.category)".localizedCaseInsensitiveContains(search) }.sorted { $0.favorite && !$1.favorite }) { service in
                NavigationLink { ServiceEditor(existing: service) } label: { HStack { if service.favorite { Image(systemName: "star.fill").foregroundStyle(.orange) }; VStack(alignment: .leading) { Text(service.title); Text(service.category).font(.caption) }; Spacer(); Text(service.price.hryvnia) } }
            }
        }.navigationTitle("Прайс").searchable(text: $search, prompt: "Назва або категорія")
            .toolbar { NavigationLink { ServiceEditor() } label: { Image(systemName: "plus") } }
    }
}
struct ServiceEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var existing: Service?
    @State private var title = ""
    @State private var category = "Ремонт"
    @State private var price = 0
    @State private var favorite = false
    var body: some View {
        Form {
            TextField("Назва послуги", text: $title)
            TextField("Категорія", text: $category)
            MoneyField(title: "Ціна, грн", amount: $price)
            Toggle("Улюблена", isOn: $favorite)
            Button("Зберегти") {
                if store.change({ db in
                    if let existing, let index = db.services.firstIndex(where: { $0.id == existing.id }) { db.services[index].title = title; db.services[index].category = category; db.services[index].price = price; db.services[index].favorite = favorite }
                    else { db.services.append(Service(category: category, title: title, price: price, favorite: favorite)) }
                }) { dismiss() }
            }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }.navigationTitle("Послуга").onAppear { if let existing { title = existing.title; category = existing.category; price = existing.price; favorite = existing.favorite } }
    }
}
struct ServicePicker: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    let select: (Service) -> Void
    var body: some View {
        List {
            if store.data.services.isEmpty { Text("Прайс порожній. Послуги можна додати в Меню → Прайс.") }
            ForEach(store.data.services.filter { search.isEmpty || "\($0.title) \($0.category)".localizedCaseInsensitiveContains(search) }.sorted { $0.favorite && !$1.favorite }) { service in
                Button { select(service) } label: { HStack { Text(service.title); Spacer(); Text(service.price.hryvnia) } }
            }
        }.navigationTitle("Вибрати роботу").searchable(text: $search).toolbar { Button("Закрити") { dismiss() } }
    }
}
struct ScheduleView: View {
    @EnvironmentObject var store: Store
    @State private var date = Date()
    private var dayItems: [(Order, Garment)] { store.data.active.flatMap { order in order.items.filter { Calendar.current.isDate($0.due, inSameDayAs: date) }.map { (order, $0) } }.sorted { $0.1.urgent && !$1.1.urgent } }
    var body: some View {
        List {
            DatePicker("Дата", selection: $date, displayedComponents: .date).datePickerStyle(.graphical)
            Text("\(dayItems.filter { !$0.1.status.unfinished }.count) із \(dayItems.count) готово").font(.headline)
            if !store.data.settings.workingDays.contains(Calendar.current.component(.weekday, from: date)) { Text("Вихідний день за налаштуваннями").foregroundStyle(.secondary) }
            ForEach(dayItems.map { ScheduleEntry(order: $0.0, item: $0.1) }) { entry in
                NavigationLink { OrderDetail(id: entry.order.id) } label: { VStack(alignment: .leading) { Text("\(entry.order.label(entry.item)) · \(entry.item.name)"); Text("\(store.data.clientName(entry.order)) · \(entry.item.status.rawValue)").font(.caption) } }
            }
            NavigationLink("Усі прострочені") { OrdersView(filter: "Прострочені") }
        }.navigationTitle("Календар")
    }
    private struct ScheduleEntry: Identifiable { let order: Order; let item: Garment; var id: UUID { item.id } }
}
struct TrashView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        List {
            Text("Записи зберігаються без автоматичного очищення. Платежі враховуються в підсумках навіть після переміщення замовлення до кошика.").font(.footnote)
            ForEach(store.data.orders.filter { $0.deletedAt != nil }) { order in
                VStack(alignment: .leading) { OrderRow(order: order); Button("Відновити") { store.change { db in if let index = db.orders.firstIndex(where: { $0.id == order.id }) { db.orders[index].deletedAt = nil } } } }
            }
        }.navigationTitle("Кошик")
    }
}

import SwiftUI
import LocalAuthentication

@main struct AtelierApp: App {
    @StateObject private var store = Store()
    var body: some Scene { WindowGroup { RootView().environmentObject(store) } }
}
struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) private var phase
    @State private var unlocked = false
    @State private var authenticating = false
    var body: some View {
        Group {
            if !store.available {
                ContentUnavailableView("База недоступна", systemImage: "exclamationmark.triangle", description: Text(store.error ?? "Перезапустіть застосунок"))
            } else if store.data.settings.lockEnabled && !unlocked {
                VStack(spacing: 24) {
                    Image(systemName: "lock.shield").font(.system(size: 60))
                    Text("Ательє").font(.largeTitle.bold())
                    Button("Відкрити з Face ID або кодом iPhone", action: authenticate).buttonStyle(.borderedProminent).disabled(authenticating)
                }
            } else {
                TabView {
                    NavigationStack { HomeView() }.tabItem { Label("Головна", systemImage: "house") }
                    NavigationStack { OrdersView() }.tabItem { Label("Замовлення", systemImage: "list.bullet.rectangle") }
                    NavigationStack { ClientsView() }.tabItem { Label("Клієнти", systemImage: "person.2") }
                    NavigationStack { SummaryView() }.tabItem { Label("Підсумки", systemImage: "chart.bar") }
                    NavigationStack { MenuView() }.tabItem { Label("Меню", systemImage: "ellipsis.circle") }
                }.tint(.teal)
            }
        }
        .onChange(of: phase) { _, next in if next == .background { unlocked = false } }
        .alert("Не вдалося виконати дію", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("Добре") { store.error = nil } } message: { Text(store.error ?? "") }
    }
    private func authenticate() {
        let context = LAContext(); authenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Відкрити замовлення Ательє") { success, error in
            Task { @MainActor in authenticating = false; unlocked = success; if !success { store.error = error?.localizedDescription ?? "Доступ не підтверджено" } }
        }
    }
}
struct HomeView: View {
    @EnvironmentObject var store: Store
    private var items: [Garment] { store.data.active.flatMap(\.items) }
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    metric("У роботі", count: items.filter { $0.status.unfinished }.count, filter: "У роботі")
                    metric("Готові", count: items.filter { $0.status == .ready }.count, filter: "Готові")
                    metric("На сьогодні", count: items.filter { $0.status != .issued && Calendar.current.isDateInToday($0.due) }.count, filter: "Сьогодні")
                    metric("Прострочені", count: items.filter { $0.status.unfinished && $0.due < Calendar.current.startOfDay(for: Date()) }.count, filter: "Прострочені")
                }
                NavigationLink { OrderEditor() } label: { Label("НОВЕ ЗАМОВЛЕННЯ", systemImage: "plus.circle.fill").frame(maxWidth: .infinity).padding() }.buttonStyle(.borderedProminent)
                NavigationLink { OrderEditor(quick: true) } label: { Label("ШВИДКИЙ РЕМОНТ", systemImage: "bolt.fill").frame(maxWidth: .infinity).padding() }.buttonStyle(.bordered)
                if !store.data.drafts.isEmpty { NavigationLink("Чернетки: \(store.data.drafts.count)") { DraftsView() } }
                if backupDue { NavigationLink { BackupView() } label: { Label("Час зберегти резервну копію", systemImage: "externaldrive.badge.exclamationmark") } }
                NavigationLink("Найближчі терміни") { ScheduleView() }
                Text("Номер речі можна написати на паперовій бірці. Друк з’явиться в оновленні.").font(.footnote).foregroundStyle(.secondary)
            }.padding()
        }.navigationTitle("Ательє")
    }
    private var backupDue: Bool { guard let last = store.data.settings.lastBackup else { return true }; return Date().timeIntervalSince(last) >= Double(store.data.settings.backupDays) * 86400 }
    private func metric(_ title: String, count: Int, filter: String) -> some View {
        NavigationLink { OrdersView(filter: filter) } label: {
            VStack(alignment: .leading, spacing: 8) { Text(count.description).font(.largeTitle.bold()); Text(title).font(.headline) }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}
struct OrdersView: View {
    @EnvironmentObject var store: Store
    @State var filter = "Активні"
    @State private var search = ""
    private let filters = ["Активні", "У роботі", "Готові", "Сьогодні", "Прострочені", "Видані", "Борги", "Усі"]
    private var orders: [Order] {
        store.data.active.filter { order in
            let match: Bool
            switch filter {
            case "У роботі": match = order.items.contains { $0.status.unfinished }
            case "Готові": match = order.items.contains { $0.status == .ready }
            case "Сьогодні": match = order.items.contains { $0.status != .issued && Calendar.current.isDateInToday($0.due) }
            case "Прострочені": match = order.items.contains { $0.status.unfinished && $0.due < Calendar.current.startOfDay(for: Date()) }
            case "Видані": match = order.items.allSatisfy { $0.status == .issued }
            case "Борги": match = store.data.debt(order) > 0
            case "Усі": match = true
            default: match = order.items.contains { $0.status != .issued }
            }
            let client = store.data.clients.first { $0.id == order.clientID }
            let text = "\(order.number) \(client?.name ?? "") \(client?.phone ?? "") \(order.items.map(\.name).joined(separator: " "))"
            return match && (search.isEmpty || text.localizedCaseInsensitiveContains(search))
        }.sorted { a, b in
            if filter == "Прострочені" {
                let au = a.items.contains { $0.urgent && $0.status.unfinished && $0.due < Calendar.current.startOfDay(for: Date()) }
                let bu = b.items.contains { $0.urgent && $0.status.unfinished && $0.due < Calendar.current.startOfDay(for: Date()) }
                if au != bu { return au }
            }
            return a.number > b.number
        }
    }
    var body: some View {
        List {
            Picker("Показати", selection: $filter) { ForEach(filters, id: \.self) { Text($0) } }
            ForEach(orders) { order in NavigationLink { OrderDetail(id: order.id) } label: { OrderRow(order: order) } }
            if orders.isEmpty { Text("Замовлень немає").foregroundStyle(.secondary) }
        }.navigationTitle(filter == "Борги" ? "Боржники" : "Замовлення")
            .searchable(text: $search, prompt: "Ім’я, телефон, номер або річ")
            .toolbar { NavigationLink { OrderEditor() } label: { Image(systemName: "plus") } }
    }
}
struct OrderRow: View {
    @EnvironmentObject var store: Store
    let order: Order
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("№ \(order.number) · \(store.data.clientName(order))").font(.headline)
            Text(order.items.map(\.name).joined(separator: ", ")).foregroundStyle(.secondary)
            HStack { Text(order.total.hryvnia); Spacer(); if store.data.debt(order) > 0 { Text("Борг \(store.data.debt(order).hryvnia)").foregroundStyle(.orange) } }
        }
    }
}
struct ClientsView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    var body: some View {
        List(store.data.clients.filter { search.isEmpty || "\($0.name) \($0.phone)".localizedCaseInsensitiveContains(search) }.sorted { $0.name < $1.name }) { client in
            NavigationLink { ClientDetail(id: client.id) } label: { VStack(alignment: .leading) { Text(client.name); if !client.phone.isEmpty { Text(client.phone).foregroundStyle(.secondary) } } }
        }.navigationTitle("Клієнти").searchable(text: $search, prompt: "Ім’я або телефон")
    }
}
struct ClientDetail: View {
    @EnvironmentObject var store: Store
    let id: UUID
    var body: some View {
        if let client = store.data.clients.first(where: { $0.id == id }) {
            List {
                Section("Клієнт") {
                    TextField("Ім’я", text: Binding(get: { client.name }, set: { value in store.change { db in if let i = db.clients.firstIndex(where: { $0.id == id }) { db.clients[i].name = value } } }))
                    TextField("Телефон", text: Binding(get: { client.phone }, set: { value in store.change { db in if let i = db.clients.firstIndex(where: { $0.id == id }) { db.clients[i].phone = value } } })).keyboardType(.phonePad)
                    if let url = URL(string: "tel:\(client.phone.filter { $0.isNumber || $0 == "+" })"), !client.phone.isEmpty { Link("Зателефонувати", destination: url) }
                    TextField("Домовленість / примітка", text: Binding(get: { client.note }, set: { value in store.change { db in if let i = db.clients.firstIndex(where: { $0.id == id }) { db.clients[i].note = value } } }), axis: .vertical)
                    Text("Борг: \(store.data.active.filter { $0.clientID == id }.reduce(0) { $0 + store.data.debt($1) }.hryvnia)")
                }
                Section("Історія замовлень") { ForEach(store.data.active.filter { $0.clientID == id }.sorted { $0.number > $1.number }) { order in NavigationLink { OrderDetail(id: order.id) } label: { OrderRow(order: order) } } }
            }.navigationTitle(client.name)
        }
    }
}

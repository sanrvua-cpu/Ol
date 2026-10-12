import SwiftUI
import CryptoKit
import CommonCrypto
import Security
import UniformTypeIdentifiers

struct BackupEnvelope: Codable {
    var format = "atelier-backup-v1"
    var salt: Data
    var rounds = 210_000
    var ciphertext: Data
}
enum Backup {
    private static func key(password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        guard password.count >= 8, salt.count == 16, rounds == 210_000 else { throw AppError.message("Пароль має містити щонайменше 8 символів; файл має бути формату Ательє") }
        let pass = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let result = pass.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self), pass.count,
                    saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &derived, 32)
            }
        }
        guard result == kCCSuccess else { throw AppError.message("Не вдалося зашифрувати копію") }
        return SymmetricKey(data: derived)
    }
    static func encrypt(_ db: Database, password: String) throws -> Data {
        var salt = Data(count: 16)
        let result = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard result == errSecSuccess else { throw AppError.message("Помилка генератора ключа") }
        let key = try key(password: password, salt: salt, rounds: 210_000)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(db), using: key)
        guard let bytes = sealed.combined else { throw AppError.message("Помилка резервування") }
        return try JSONEncoder().encode(BackupEnvelope(salt: salt, ciphertext: bytes))
    }
    static func decrypt(_ data: Data, password: String) throws -> Database {
        guard data.count <= 100_000_000 else { throw AppError.message("Файл завеликий") }
        let envelope = try JSONDecoder().decode(BackupEnvelope.self, from: data)
        guard envelope.format == "atelier-backup-v1" else { throw AppError.message("Невідомий формат копії") }
        let key = try key(password: password, salt: envelope.salt, rounds: envelope.rounds)
        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.ciphertext), using: key)
        let db = try JSONDecoder().decode(Database.self, from: bytes)
        try db.validate(); return db
    }
}
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct BackupView: View {
    @EnvironmentObject var store: Store
    @State private var password = ""
    @State private var document: BackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var pending: Database?
    @State private var busy = false
    @State private var message = ""
    var body: some View {
        Form {
            Section("Зашифрована резервна копія") {
                SecureField("Пароль копії, від 8 символів", text: $password)
                Text("Збережіть пароль: він потрібен для відновлення на іншому iPhone.").font(.footnote)
                Button("Створити й зберегти копію") { createBackup() }.disabled(password.count < 8 || busy)
                Button("Відновити з файлу") { importing = true }.disabled(password.count < 8 || busy)
                if busy { ProgressView() }
                if !message.isEmpty { Text(message) }
                if let last = store.data.settings.lastBackup { Text("Остання копія: \(last.formatted(date: .abbreviated, time: .shortened))") }
                Stepper("Нагадувати через \(store.data.settings.backupDays) днів", value: Binding(get: { store.data.settings.backupDays }, set: { value in store.change { $0.settings.backupDays = value } }), in: 1...30)
            }
        }
        .navigationTitle("Резервна копія")
        .fileExporter(isPresented: $exporting, document: document, contentType: .data, defaultFilename: "Atelier-\(Date().formatted(.iso8601.year().month().day())).atelier") { result in
            switch result {
            case .success: store.change { $0.settings.lastBackup = Date() }; message = "Копію успішно збережено"
            case .failure(let error): store.error = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let bytes = try Data(contentsOf: url)
                let pass = password; busy = true
                Task {
                    do { pending = try await Task.detached { try Backup.decrypt(bytes, password: pass) }.value }
                    catch { store.error = "Не вдалося відкрити копію. Перевірте пароль і файл." }
                    busy = false
                }
            } catch { store.error = error.localizedDescription }
        }
        .alert("Замінити поточні дані?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Скасувати", role: .cancel) { pending = nil }
            Button("Відновити", role: .destructive) { if let db = pending, store.replace(with: db) { message = "Дані відновлено" }; pending = nil }
        } message: { Text("Буде відновлено \(pending?.orders.count ?? 0) замовлень. Поточні дані заміняться; локальна захисна копія збережеться.") }
    }
    private func createBackup() {
        let snapshot = store.data, pass = password; busy = true
        Task {
            do { document = try await Task.detached { BackupDocument(data: try Backup.encrypt(snapshot, password: pass)) }.value; exporting = true }
            catch { store.error = error.localizedDescription }
            busy = false
        }
    }
}

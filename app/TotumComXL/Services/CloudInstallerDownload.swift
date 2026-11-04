import AppKit
import Foundation

/// Установщик программы поставщика облака: скачивается с его официального адреса в
/// «Загрузки», проверяется подпись разработчика, файл показывается в Finder. Запускает
/// его человек сам — программа установщики не запускает.
enum CloudInstallerDownload {

    enum Failure: Error, Equatable {
        case noDirectAddress
        case unsigned(String)
        case wrongSigner(found: String, expected: String)
        case nothingInside
    }

    @MainActor
    static func fetch(_ provider: CloudProvider) async {
        guard let url = provider.installerURL else { return }
        let ok = DialogService.shared.showConfirmation(
            title: L("cloud.install.confirm.title", provider.title),
            message: L("cloud.install.confirm.message", provider.title, url.host ?? ""))
        guard ok else { return }

        let destination = freeDownloadsURL(named: provider.installerFileName)
        var job: Task<Void, Error>?
        let progress = DialogService.shared.showProgress(
            title: L("cloud.install.downloading", provider.title),
            message: destination.lastPathComponent,
            cancelHandler: { job?.cancel() })
        progress.update(currentFile: destination.lastPathComponent, progress: 0,
                        bytesDone: 0, bytesTotal: 0, filesDone: 0, filesTotal: 1)

        job = Task {
            try await download(url, to: destination) { done, total in
                Task { @MainActor in
                    let fraction = total > 0 ? Double(done) / Double(total) : 0
                    progress.update(currentFile: destination.lastPathComponent, progress: fraction,
                                    bytesDone: done, bytesTotal: total, filesDone: 0, filesTotal: 1)
                }
            }
            progress.setIndeterminate(true)
            progress.update(progress: 1, message: L("cloud.install.checking"))
            try await Task.detached(priority: .userInitiated) {
                try verify(installer: destination, signer: provider.signer)
            }.value
        }
        do {
            try await job?.value
            progress.close()
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            DialogService.shared.showInfo(title: L("cloud.install.done.title", provider.title),
                                          message: L("cloud.install.done.message", destination.lastPathComponent))
        } catch is CancellationError {
            progress.close()
            try? FileManager.default.removeItem(at: destination)
        } catch {
            progress.close()
            try? FileManager.default.removeItem(at: destination)
            DialogService.shared.showError(title: L("cloud.install.failed.title", provider.title),
                                           message: message(for: error))
        }
    }

    // MARK: - Загрузка

    /// Свободное имя в «Загрузках»: «OneDrive.pkg», «OneDrive (2).pkg», …
    static func freeDownloadsURL(named name: String,
                                 in folder: URL = FileManager.default.urls(for: .downloadsDirectory,
                                                                           in: .userDomainMask).first!,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while exists(candidate) {
            candidate = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    private final class Progress: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
        let report: @Sendable (Int64, Int64) -> Void
        init(report: @escaping @Sendable (Int64, Int64) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            report(totalBytesWritten, totalBytesExpectedToWrite)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }

    /// Скачать по адресу поставщика с отчётом о ходе; отмена задачи снимает запрос.
    static func download(_ url: URL, to destination: URL,
                         report: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("TotumCommander", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request,
                                                                          delegate: Progress(report: report))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    // MARK: - Проверка подписи

    /// Подпись установщика: пакет — через pkgutil, программа — через codesign; образ
    /// подключается только для чтения, проверяется первое, что в нём лежит, и отключается.
    static func verify(installer: URL, signer: String) throws {
        switch installer.pathExtension.lowercased() {
        case "pkg":
            try check(signerOf: try UpdateSteps.run("/usr/sbin/pkgutil", ["--check-signature", installer.path]),
                      expected: signer)
        case "dmg":
            let mountPoint = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("totum-cloud-\(UUID().uuidString)")
            _ = try UpdateSteps.mount(dmg: installer, at: mountPoint)
            defer { UpdateSteps.detach(mountPoint) }
            let items = (try? FileManager.default.contentsOfDirectory(at: mountPoint,
                                                                      includingPropertiesForKeys: nil)) ?? []
            if let pkg = items.first(where: { $0.pathExtension == "pkg" }) {
                try check(signerOf: try UpdateSteps.run("/usr/sbin/pkgutil", ["--check-signature", pkg.path]),
                          expected: signer)
            } else if let app = items.first(where: { $0.pathExtension == "app" }) {
                try check(signerOf: try UpdateSteps.run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path]),
                          expected: signer)
            } else {
                throw Failure.nothingInside
            }
        default:
            try check(signerOf: try UpdateSteps.run("/usr/bin/codesign", ["-dv", "--verbose=2", installer.path]),
                      expected: signer)
        }
    }

    /// Имя разработчика из выдачи pkgutil («1. Developer ID Installer: Google LLC (…)») или
    /// codesign («Authority=Developer ID Application: Dropbox, Inc. (…)»). Нет — не подписан.
    static func developerName(in output: String) -> String? {
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            for marker in ["Developer ID Installer: ", "Developer ID Application: "] {
                if let range = text.range(of: marker) {
                    let rest = text[range.upperBound...]
                    let name = rest.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? String(rest)
                    if !name.isEmpty { return name }
                }
            }
        }
        return nil
    }

    static func check(signerOf output: String, expected: String) throws {
        guard let name = developerName(in: output) else {
            throw Failure.unsigned(String(output.prefix(200)))
        }
        guard name.range(of: expected, options: .caseInsensitive) != nil else {
            throw Failure.wrongSigner(found: name, expected: expected)
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case Failure.unsigned:
            return L("cloud.install.unsigned")
        case Failure.wrongSigner(let found, let expected):
            return L("cloud.install.wrongSigner", found, expected)
        case Failure.nothingInside:
            return L("cloud.install.nothingInside")
        case Failure.noDirectAddress:
            return L("cloud.install.noAddress")
        default:
            return error.localizedDescription
        }
    }
}

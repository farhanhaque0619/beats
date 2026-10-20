import SwiftUI
import QuickLook
import InkCore
#if os(macOS)
import AppKit
#endif

/// Attachment chips under a message body. Tap previews (Quick Look on iPhone, the default app on
/// Mac); the context menu shares or saves a copy.
struct ReaderAttachmentStrip: View {
    let message: MessageSummary
    let attachments: [Attachment]

    @Environment(MailStore.self) private var store
    /// Temporary files, written once per attachment so Share and Quick Look have a real file.
    @State private var files: [String: URL] = [:]
    @State private var preparingID: String?
    @State private var previewURL: URL?
    @State private var exportURL: URL?
    @State private var isExporting = false

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: InkSpace.s) {
                ForEach(attachments) { attachment in
                    ReaderAttachmentChip(
                        attachment: attachment,
                        fileURL: files[attachment.id],
                        isPreparing: preparingID == attachment.id,
                        actions: ReaderAttachmentChip.Actions(
                            open: { open(attachment) },
                            preview: { preview(attachment) },
                            save: { save(attachment) },
                            saveToDownloads: { saveToDownloads(attachment) }
                        )
                    )
                }
            }
            .padding(.horizontal, InkSpace.gutter)
        }
        .scrollIndicators(.hidden)
        .quickLookPreview($previewURL)
        .fileMover(isPresented: $isExporting, file: exportURL) { result in
            exportURL = nil
            switch result {
            case .success:
                Haptics.success()
                store.showToast(Toast(message: "Saved", systemImage: "checkmark.circle", style: .success))
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    showFailure("Couldn't save the attachment.")
                }
            }
        }
        .task(id: message.id) { await prepareFiles() }
    }

    // MARK: Actions

    private func open(_ attachment: Attachment) {
        Haptics.tick()
        Task {
            guard let url = await fileURL(for: attachment) else { return }
            #if os(macOS)
            _ = NSWorkspace.shared.open(url)
            #else
            previewURL = url
            #endif
        }
    }

    private func preview(_ attachment: Attachment) {
        Task {
            guard let url = await fileURL(for: attachment) else { return }
            previewURL = url
        }
    }

    private func save(_ attachment: Attachment) {
        Task {
            guard let source = await fileURL(for: attachment) else { return }
            do {
                exportURL = try await ReaderAttachmentFiles.exportCopy(of: source)
                isExporting = true
            } catch {
                showFailure("Couldn't save the attachment.")
            }
        }
    }

    private func saveToDownloads(_ attachment: Attachment) {
        #if os(macOS)
        Task {
            guard let source = await fileURL(for: attachment) else { return }
            do {
                let saved = try await ReaderAttachmentFiles.copyToDownloads(source)
                NSWorkspace.shared.activateFileViewerSelecting([saved])
                Haptics.success()
                store.showToast(Toast(message: "Saved to Downloads", systemImage: "arrow.down.circle", style: .success))
            } catch {
                showFailure("Couldn't save to Downloads.")
            }
        }
        #endif
    }

    // MARK: Files

    private func prepareFiles() async {
        for attachment in attachments where files[attachment.id] == nil {
            guard let data = attachment.data else { continue }
            let folder = ReaderAttachmentFiles.folder(messageID: message.id, attachmentID: attachment.id)
            if let url = try? await ReaderAttachmentFiles.write(data, named: attachment.filename, folder: folder) {
                files[attachment.id] = url
            }
        }
    }

    /// The attachment as a file, downloading the message again when the cache kept only its
    /// metadata (very large attachments).
    private func fileURL(for attachment: Attachment) async -> URL? {
        if let url = files[attachment.id] { return url }
        preparingID = attachment.id
        defer { preparingID = nil }
        guard let data = await attachmentData(for: attachment) else {
            showFailure("This attachment isn't available right now.")
            return nil
        }
        do {
            let folder = ReaderAttachmentFiles.folder(messageID: message.id, attachmentID: attachment.id)
            let url = try await ReaderAttachmentFiles.write(data, named: attachment.filename, folder: folder)
            files[attachment.id] = url
            return url
        } catch {
            showFailure("Couldn't open the attachment.")
            return nil
        }
    }

    private func attachmentData(for attachment: Attachment) async -> Data? {
        if let data = attachment.data { return data }
        guard let body = try? await store.body(for: message) else { return nil }
        return body.attachments.first { $0.id == attachment.id }?.data
    }

    private func showFailure(_ message: String) {
        Haptics.warning()
        store.showToast(Toast(message: message, systemImage: "exclamationmark.circle", style: .error))
    }
}

// MARK: - Chip

private struct ReaderAttachmentChip: View {
    struct Actions {
        var open: () -> Void
        var preview: () -> Void
        var save: () -> Void
        var saveToDownloads: () -> Void
    }

    let attachment: Attachment
    let fileURL: URL?
    let isPreparing: Bool
    let actions: Actions

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous)
    }

    var body: some View {
        Button(action: actions.open) {
            HStack(spacing: InkSpace.s) {
                ZStack {
                    RoundedRectangle(cornerRadius: InkRadius.small, style: .continuous)
                        .fill(Ink.background)
                    if isPreparing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: ReaderAttachmentKind.symbol(for: attachment))
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(Ink.primary)
                    }
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(InkFont.caption)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, InkSpace.m)
            .padding(.vertical, 6)
            .frame(maxWidth: 240, alignment: .leading)
            .background(Ink.surface, in: shape)
            .overlay(shape.stroke(Ink.hairline, lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .contextMenu { menu }
        .accessibilityLabel("\(displayName), \(detail)")
        .accessibilityHint("Opens the attachment")
    }

    @ViewBuilder private var menu: some View {
        #if os(macOS)
        Button(action: actions.open) { Label("Open", systemImage: "arrow.up.forward.app") }
        Button(action: actions.preview) { Label("Quick Look", systemImage: "eye") }
        #else
        Button(action: actions.preview) { Label("Preview", systemImage: "eye") }
        #endif
        if let fileURL {
            ShareLink(item: fileURL) { Label("Share", systemImage: "square.and.arrow.up") }
        }
        Button(action: actions.save) { Label("Save…", systemImage: "square.and.arrow.down") }
        #if os(macOS)
        Button(action: actions.saveToDownloads) { Label("Save to Downloads", systemImage: "arrow.down.circle") }
        #endif
    }

    private var displayName: String {
        attachment.filename.isEmpty ? "Attachment" : attachment.filename
    }

    /// "PDF · 1.2 MB".
    private var detail: String {
        let size = InkFormat.fileSize(attachment.size > 0 ? attachment.size : (attachment.data?.count ?? 0))
        let kind = ReaderAttachmentKind.label(for: attachment)
        return kind.isEmpty ? size : "\(kind) · \(size)"
    }
}

/// Icons and short type labels for attachments.
private enum ReaderAttachmentKind {
    static func symbol(for attachment: Attachment) -> String {
        let type = attachment.mimeType.lowercased()
        let ext = (attachment.filename as NSString).pathExtension.lowercased()
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type == "application/pdf" || ext == "pdf" { return "doc.richtext" }
        if type == "text/calendar" || ext == "ics" { return "calendar" }
        if ["zip", "gz", "tgz", "rar", "7z", "tar"].contains(ext) || type.contains("zip") || type.contains("compressed") {
            return "doc.zipper"
        }
        if ["xls", "xlsx", "csv", "numbers", "ods"].contains(ext) || type.contains("spreadsheet") || type.contains("excel") {
            return "tablecells"
        }
        if ["ppt", "pptx", "key", "odp"].contains(ext) || type.contains("presentation") || type.contains("powerpoint") {
            return "rectangle.stack"
        }
        if type.hasPrefix("text/") || ["doc", "docx", "pages", "rtf", "txt", "md", "odt"].contains(ext) || type.contains("word") {
            return "doc.text"
        }
        return "doc"
    }

    static func label(for attachment: Attachment) -> String {
        let ext = (attachment.filename as NSString).pathExtension
        if !ext.isEmpty, ext.count <= 5 { return ext.uppercased() }
        let subtype = attachment.mimeType.split(separator: "/").last.map(String.init) ?? ""
        return subtype.count <= 5 ? subtype.uppercased() : ""
    }
}

// MARK: - Temporary files

/// Attachment files under the app's temporary directory (the system clears it on its own).
enum ReaderAttachmentFiles {
    private static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Ink Attachments", isDirectory: true)
    }

    /// A stable folder name per message and part, so each file keeps its original name.
    static func folder(messageID: String, attachmentID: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(messageID)#\(attachmentID)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    static func write(_ data: Data, named filename: String, folder: String) async throws -> URL {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        let name = sanitized(filename)
        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name, isDirectory: false)
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }

    /// A throwaway copy for the save panel, which moves the file it's given.
    static func exportCopy(of source: URL) async throws -> URL {
        let directory = root
            .appendingPathComponent("Export", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(source.lastPathComponent, isDirectory: false)
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        }.value
    }

    #if os(macOS)
    /// Copies into ~/Downloads, adding " 2", " 3"… instead of overwriting.
    static func copyToDownloads(_ source: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            guard let downloads = manager.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            let base = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            var destination = downloads.appendingPathComponent(source.lastPathComponent, isDirectory: false)
            var counter = 2
            while manager.fileExists(atPath: destination.path) {
                let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                destination = downloads.appendingPathComponent(name, isDirectory: false)
                counter += 1
            }
            try manager.copyItem(at: source, to: destination)
            return destination
        }.value
    }
    #endif

    /// A filename that is safe on disk: no path separators or control characters.
    static func sanitized(_ filename: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.newlines)
        var scalars = String.UnicodeScalarView()
        for scalar in filename.unicodeScalars {
            scalars.append(forbidden.contains(scalar) ? Unicode.Scalar(UInt8(ascii: "-")) : scalar)
        }
        let cleaned = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !cleaned.isEmpty else { return "Attachment" }
        return String(cleaned.prefix(180))
    }
}

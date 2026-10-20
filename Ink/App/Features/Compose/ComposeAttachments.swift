import SwiftUI
import InkCore
import ImageIO
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
import UIKit
#endif

/// Turns picked files and photos into `OutgoingAttachment`s, reading and converting off the
/// main thread.
enum ComposeAttachmentLoader {
    /// Reads files from the file importer or a drop. Files that can't be read are skipped.
    static func attachments(from urls: [URL]) async -> [OutgoingAttachment] {
        await Task.detached(priority: .userInitiated) {
            urls.compactMap { ComposeAttachmentLoader.readFile($0) }
        }.value
    }

    /// "application/pdf" for "Report.pdf"; `application/octet-stream` when unknown.
    static func mimeType(forFilename filename: String) -> String {
        let pathExtension = (filename as NSString).pathExtension
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension),
              let mime = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }

    /// SF Symbol for an attachment's kind.
    static func symbol(for attachment: OutgoingAttachment) -> String {
        let type = UTType(mimeType: attachment.mimeType)
            ?? UTType(filenameExtension: (attachment.filename as NSString).pathExtension)
        guard let type else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .spreadsheet) { return "tablecells" }
        if type.conforms(to: .presentation) { return "rectangle.on.rectangle" }
        if type.conforms(to: .calendarEvent) { return "calendar" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }

    /// A small preview of an image attachment, decoded off the main thread.
    @MainActor
    static func thumbnail(for attachment: OutgoingAttachment, maxPixelSize: Int = 120) async -> Image? {
        guard attachment.mimeType.lowercased().hasPrefix("image/") else { return nil }
        let data = attachment.data
        let box = await Task.detached(priority: .utility) { () -> ComposeThumbnailBox? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return ComposeThumbnailBox(image: image)
        }.value
        guard let box else { return nil }
        return Image(decorative: box.image, scale: 1)
    }

    private static func readFile(_ url: URL) -> OutgoingAttachment? {
        // Files from the importer live outside the sandbox until we ask for access.
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let filename = url.lastPathComponent
        return OutgoingAttachment(filename: filename, mimeType: mimeType(forFilename: filename), data: data)
    }

    #if os(iOS)
    /// Loads a photo or video from the library. HEIC and other Apple-only image formats become
    /// JPEG so every recipient can open them.
    static func attachment(from item: PhotosPickerItem, number: Int) async -> OutgoingAttachment? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let types = item.supportedContentTypes
        let type = types.first(where: { $0.conforms(to: .image) || $0.conforms(to: .movie) }) ?? types.first
        let isImage = type?.conforms(to: .image) ?? false
        let baseName = isImage ? "Photo \(number)" : "Video \(number)"
        if isImage, let type, !(type.conforms(to: .jpeg) || type.conforms(to: .png) || type.conforms(to: .gif)),
           let jpeg = await jpegData(from: data) {
            return OutgoingAttachment(filename: "\(baseName).jpg", mimeType: "image/jpeg", data: jpeg)
        }
        let pathExtension = type?.preferredFilenameExtension ?? (isImage ? "jpg" : "mov")
        let mime = type?.preferredMIMEType ?? mimeType(forFilename: "\(baseName).\(pathExtension)")
        return OutgoingAttachment(filename: "\(baseName).\(pathExtension)", mimeType: mime, data: data)
    }

    private static func jpegData(from data: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            UIImage(data: data)?.jpegData(compressionQuality: 0.85)
        }.value
    }
    #endif
}

/// Carries a decoded thumbnail from the decoding task back to the main actor. CGImage is
/// immutable, so handing it across is safe.
private struct ComposeThumbnailBox: @unchecked Sendable {
    let image: CGImage
}

/// Attachments under the message: thumbnail or type icon, name, size, remove. Shows a note
/// when something couldn't be attached or the total is over what most providers accept.
struct ComposeAttachmentStrip: View {
    private let attachments: [OutgoingAttachment]
    private let isLoading: Bool
    private let note: String?
    private let onRemove: (OutgoingAttachment) -> Void

    /// Most providers refuse messages over 25 MB.
    private static let sizeLimit = 25 * 1024 * 1024

    init(attachments: [OutgoingAttachment], isLoading: Bool, note: String?, onRemove: @escaping (OutgoingAttachment) -> Void) {
        self.attachments = attachments
        self.isLoading = isLoading
        self.note = note
        self.onRemove = onRemove
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InkSpace.xs) {
            ScrollView(.horizontal) {
                HStack(spacing: InkSpace.s) {
                    ForEach(attachments) { attachment in
                        ComposeAttachmentChip(attachment: attachment) { onRemove(attachment) }
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                    if isLoading {
                        LoadingDots()
                            .frame(height: 48)
                            .padding(.horizontal, InkSpace.m)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, InkSpace.gutter)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)

            if let footnote {
                Text(footnote.text)
                    .font(.footnote)
                    .foregroundStyle(footnote.isWarning ? Ink.danger : Ink.tertiary)
                    .padding(.horizontal, InkSpace.gutter)
                    .transition(.opacity)
            }
        }
        .animation(InkMotion.snappy, value: attachments.map(\.id))
        .animation(InkMotion.snappy, value: isLoading)
    }

    private var totalSize: Int {
        attachments.reduce(0) { $0 + $1.data.count }
    }

    private var footnote: (text: String, isWarning: Bool)? {
        if let note { return (note, true) }
        let total = totalSize
        if total > Self.sizeLimit {
            return ("\(InkFormat.fileSize(total)) in total, more than the 25 MB most providers accept", true)
        }
        if attachments.count > 1 {
            return ("\(attachments.count) attachments · \(InkFormat.fileSize(total))", false)
        }
        return nil
    }
}

private struct ComposeAttachmentChip: View {
    let attachment: OutgoingAttachment
    let onRemove: () -> Void

    @State private var thumbnail: Image? = nil

    init(attachment: OutgoingAttachment, onRemove: @escaping () -> Void) {
        self.attachment = attachment
        self.onRemove = onRemove
    }

    var body: some View {
        HStack(spacing: InkSpace.s) {
            preview
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(InkFormat.fileSize(attachment.data.count))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Ink.tertiary)
            }
            .frame(maxWidth: 150, alignment: .leading)
            .accessibilityElement(children: .combine)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 22, height: 22)
                    .background(Ink.fill, in: Circle())
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Remove \(attachment.filename)")
        }
        .padding(.leading, 6)
        .padding(.vertical, 6)
        .padding(.trailing, 2)
        .background(Ink.elevated, in: RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: InkRadius.medium, style: .continuous)
                .stroke(Ink.hairline, lineWidth: 0.5)
        )
        .task(id: attachment.id) {
            let image = await ComposeAttachmentLoader.thumbnail(for: attachment)
            withAnimation(InkMotion.fade) { thumbnail = image }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: InkRadius.small, style: .continuous)
                .fill(Ink.fill)
            if let thumbnail {
                thumbnail
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: ComposeAttachmentLoader.symbol(for: attachment))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Ink.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: InkRadius.small, style: .continuous))
        .accessibilityHidden(true)
    }
}

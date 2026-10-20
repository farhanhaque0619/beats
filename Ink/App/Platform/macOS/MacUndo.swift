#if os(macOS)
import SwiftUI
import AppKit
import InkCore

/// Puts the pending triage action (or Undo Send) on the window's undo stack while its toast
/// offers Undo, so Edit › Undo reads "Undo Archive" and ⌘Z works as it does everywhere on the
/// Mac. Text fields share the window's stack, so ⌘Z while typing still undoes typing first.
/// Also reopens Compose with a message whose send was undone.
struct MacUndoBridge: ViewModifier {
    let app: AppModel

    @Environment(\.undoManager) private var undoManager
    @State private var target = MacUndoTarget()

    func body(content: Content) -> some View {
        content
            .onChange(of: app.store.toast) { old, toast in
                register(toast)
                // Undone through the toast's own button: put the selection back too.
                if let old, old.undoable, toast == nil {
                    MacActions(app: app).restoreSelection(afterUndoOf: old.id)
                }
            }
            .onChange(of: app.store.restoredDraft?.id) { _, id in
                guard id != nil, app.composeDraft == nil, let draft = app.store.takeRestoredDraft() else { return }
                app.compose(draft)
            }
    }

    private func register(_ toast: Toast?) {
        guard let undoManager else { return }
        undoManager.removeAllActions(withTarget: target)
        guard let toast, toast.undoable else { return }
        target.app = app
        target.toastID = toast.id
        undoManager.registerUndo(withTarget: target, selector: #selector(MacUndoTarget.performUndo(_:)), object: nil)
        undoManager.setActionName(Self.actionName(for: toast))
    }

    /// "Archive" for Edit › Undo Archive, from the toast's symbol (its text is past tense).
    private static func actionName(for toast: Toast) -> String {
        switch toast.systemImage ?? "" {
        case "archivebox": return "Archive"
        case "trash": return "Move to Trash"
        case "xmark.octagon": return "Mark as Spam"
        case "folder": return "Move"
        case "tray": return "Move to Inbox"
        case "clock": return "Snooze"
        case "envelope.open": return "Mark as Read"
        case "envelope.badge": return "Mark as Unread"
        case "star.fill": return "Star"
        case "star.slash": return "Unstar"
        case "paperplane": return "Send"
        default: return ""
        }
    }
}

/// The undo manager's target: undoes through `MacActions` (which also restores the selection),
/// and only while the toast it was registered for is still the one offering Undo.
@MainActor
final class MacUndoTarget: NSObject {
    weak var app: AppModel?
    var toastID: UUID?

    @objc func performUndo(_ sender: Any?) {
        guard let app, let toast = app.store.toast, toast.id == toastID, toast.undoable else { return }
        MacActions(app: app).undo()
    }
}

extension View {
    /// ⌘Z for mail actions. See `MacUndoBridge`.
    func macUndoBridge(app: AppModel) -> some View {
        modifier(MacUndoBridge(app: app))
    }
}
#endif

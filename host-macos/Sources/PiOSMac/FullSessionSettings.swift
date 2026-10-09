import AppKit
import PiOSCore

// Settings → General's full pi session switch (decision 1–4; protocol.md "Full pi session (macOS)"): the resource mode
// `trustedGlobal`, turned on only after an acknowledgement sheet. Destructive commands are the user's own dcg hook's to
// review (its pi extension shows dcg's approval dialog); pi-os adds no confirm of its own and its computer-control
// deletion policy is unchanged. The guard line comes from GET /settings/resources `status`, content-free.

enum FullSessionCopy {
    static let toggleTitle = "Full pi session (terminal, files, your pi extensions and skills)"
    /// "Starts in": the folder is where pi begins, not a boundary (bash is not a sandbox).
    static let toggleTip = "Explicit opt-in. pi can run any command and change files, starting in the folder you’re looking at, with your pi extensions, skills and prompt templates. Changes apply to the next task."
    /// The line under the switch while it is off.
    static let offNote = "Off by default: pi stays in the window you choose."
    static let onNote = "On for your next task."
    static let needsControl = "Needs computer control: turn it on above to use the full pi session."
    static let guardedByDcg = "Destructive commands: reviewed by dcg"
    static let guardedByOther = "Commands: checked by one of your pi extensions"
    static let unguarded = "No command guard found"

    /// The acknowledgement sheet before the switch turns on.
    struct Acknowledgement: Equatable {
        var title: String
        var message: String
        var confirm: String
        var cancel: String
    }
    static let acknowledgement = Acknowledgement(
        title: "Turn on the full pi session?",
        message: "pi then works like pi in your terminal: the agent can run any command, read and change files, and use your pi extensions, skills and prompt templates. It starts in the folder you’re looking at (a Finder window, a terminal or your editor’s project), otherwise in your home folder, and saves its sessions like pi does.\n\nDestructive commands are reviewed by dcg when its pi extension is installed: dcg shows its own approval dialog before such a command runs. Without a command guard, nothing asks before a command runs. Commands and extensions run with pi-os’s permissions, including Accessibility and Screen Recording, so only turn this on for code you trust. pi-os itself still never deletes files or empties the Trash through computer control.\n\nThis applies to your next task, not to one already running.",
        confirm: "Turn On Full pi Session",
        cancel: "Keep It Off")

    /// The line under the switch: off, waiting for computer control, or which guard reviews commands. `status` nil: an
    /// older harness that reports no guard.
    static func note(mode: String?, status: ResourceStatus?) -> String {
        guard mode == "trustedGlobal" else { return offNote }
        guard let status else { return onNote }
        guard status.fullSession else { return needsControl }
        switch status.bashGuard {
        case .dcg: return guardedByDcg
        case .other: return guardedByOther
        case .unguarded: return unguarded
        }
    }

    /// The sheet as an alert (never shown by tests: they lay it out offscreen).
    @MainActor static func alert(_ copy: Acknowledgement = acknowledgement) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = copy.title
        alert.informativeText = copy.message
        alert.addButton(withTitle: copy.confirm)
        alert.addButton(withTitle: copy.cancel)
        return alert
    }

    /// The app's acknowledgement: a sheet on the Settings window (an app-modal alert without one). True turns it on.
    @MainActor static func present(_ copy: Acknowledgement, on window: NSWindow?, done: @escaping @MainActor (Bool) -> Void) {
        let alert = alert(copy)
        guard let window, window.isVisible else { done(alert.runModal() == .alertFirstButtonReturn); return }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { done(response == .alertFirstButtonReturn) }
        }
    }
}

import Cocoa

/// Inserts and deletes text in the focused app with synthetic key events.
enum Typer {
    private static let vKey: CGKeyCode = 9
    private static let deleteKey: CGKeyCode = 51
    static let returnKey: CGKeyCode = 36

    static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Waits (up to 1 s) for the user to let go of the hotkey modifiers, so
    /// they do not combine with the keys we post.
    static func waitForModifierRelease() async {
        for _ in 0..<50 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(Hotkey.modifierMask).isEmpty {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Pastes `text` via the clipboard, then restores the previous clipboard.
    static func paste(_ text: String) async {
        let board = NSPasteboard.general
        let saved: [NSPasteboardItem] = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }

        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // nspasteboard.org markers: clipboard managers skip transient, concealed items.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.clearContents()
        board.writeObjects([item])
        let ourChange = board.changeCount

        press(vKey, flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(500))

        // Restore only if nothing else has written to the clipboard since.
        if board.changeCount == ourChange {
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
        }
    }

    /// Deletes `count` user-perceived characters; one Backspace removes one
    /// grapheme cluster, which is what Swift's `String.count` counts.
    static func deleteBackward(_ count: Int) async {
        for _ in 0..<count {
            press(deleteKey)
            try? await Task.sleep(for: .milliseconds(8))
        }
    }
}

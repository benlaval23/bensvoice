import AppKit
import ApplicationServices

enum TextInsertion {
    /// Pastes text into the focused field via a temporary clipboard swap, then restores the clipboard.
    static func insert(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Tell clipboard managers to ignore this entry.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let changeCount = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pb.changeCount == changeCount else { return } // user copied something new meanwhile
            pb.clearContents()
            let items = saved.map { dict -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (t, d) in dict { item.setData(d, forType: t) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }

    /// Selected text in the focused element, via Accessibility (works in most native apps, some Electron apps).
    static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

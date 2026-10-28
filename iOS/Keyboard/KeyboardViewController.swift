import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        model.controller = self
        let host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let height = view.heightAnchor.constraint(equalToConstant: 200)
        height.priority = .init(999)
        height.isActive = true
        host.didMove(toParent: self)
        Bridge.observe(.changed) { [weak self] in self?.model.refresh() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.showsGlobe = needsInputModeSwitchKey
        model.hasFullAccess = hasFullAccess
        model.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.model.refresh() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
    }

    var textBeforeCursor: String { textDocumentProxy.documentContextBeforeInput ?? "" }
    var selectedText: String { textDocumentProxy.selectedText ?? "" }

    func insert(_ text: String) {
        var text = text
        if let last = textBeforeCursor.last, !last.isWhitespace, selectedText.isEmpty { text = " " + text }
        textDocumentProxy.insertText(text)
    }

    func nextKeyboard() { advanceToNextInputMode() }

    /// Keyboards aren't allowed to open apps directly, so walk up to the host UIApplication and ask it.
    func openApp(_ url: URL) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication, app.responds(to: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(app.method(for: selector), to: Open.self)
                open(app, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = r.next
        }
        model.localMessage = "Couldn't open BensVoice. Open the app once, then come back."
    }
}

final class KeyboardModel: ObservableObject {
    weak var controller: KeyboardViewController?
    @Published var phase = "off"
    @Published var mode: Mode?
    @Published var startedAt = Date()
    @Published var message: String?
    @Published var localMessage: String?
    @Published var showsGlobe = false
    @Published var hasFullAccess = true

    private var d: UserDefaults { Bridge.defaults }

    func refresh() {
        let alive = Bridge.sessionAlive
        let newPhase = alive ? d.string(forKey: Bridge.phaseKey) ?? "off" : "off"
        if newPhase != phase { phase = newPhase }
        mode = d.string(forKey: Bridge.modeKey).flatMap(Mode.init(rawValue:))
        startedAt = Date(timeIntervalSince1970: d.double(forKey: Bridge.startedAtKey))
        let newMessage = d.string(forKey: Bridge.messageKey)
        if newMessage != message { message = newMessage }
        deliverResult()
    }

    /// Types the result in once, and only if this keyboard asked for it.
    private func deliverResult() {
        guard let request = d.string(forKey: Bridge.requestKey), !request.isEmpty,
              d.string(forKey: Bridge.resultForKey) == request else { return }
        d.set("", forKey: Bridge.requestKey)
        if let text = d.string(forKey: Bridge.resultKey), !text.isEmpty { controller?.insert(text) }
    }

    func tap(_ tapped: Mode) {
        localMessage = nil
        guard hasFullAccess else {
            localMessage = "Turn on Allow Full Access: Settings › General › Keyboard › Keyboards › BensVoice."
            return
        }
        switch phase {
        case "recording":
            Bridge.post(.stop)
            phase = "working"
        case "working":
            return
        default:
            d.set(UUID().uuidString, forKey: Bridge.requestKey)
            d.set(controller?.textBeforeCursor ?? "", forKey: Bridge.contextKey)
            d.set(controller?.selectedText ?? "", forKey: Bridge.selectedKey)
            if Bridge.sessionAlive {
                Bridge.post(tapped == .dictate ? .startDictate : .startCompose)
                phase = "recording"
                mode = tapped
                startedAt = Date()
            } else {
                controller?.openApp(URL(string: "bensvoice://start?mode=\(tapped.rawValue)")!)
            }
        }
    }

    func cancel() {
        d.set("", forKey: Bridge.requestKey)
        Bridge.post(.cancel)
        phase = "ready"
    }

    var status: String {
        if let localMessage { return localMessage }
        switch phase {
        case "recording": return mode == .compose ? "Composing. Tap to finish." : "Dictating. Tap to finish."
        case "working": return mode == .compose ? "Claude is writing…" : "Transcribing…"
        case "ready": return message ?? "Mic is on"
        default: return message ?? "Tap to start. BensVoice opens once to turn the mic on."
        }
    }
}

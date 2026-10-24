import AppKit
import AVFoundation
import ServiceManagement

// CLI test mode: BensVoice --transcribe file.wav
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--transcribe" {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[2]))
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: src)
    let conv = AVAudioConverter(from: file.processingFormat, to: fmt)!
    let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 64)!
    var fed = false
    conv.convert(to: out, error: nil) { _, s in if fed { s.pointee = .endOfStream; return nil }; fed = true; s.pointee = .haveData; return src }
    let t0 = Date()
    let model = try Parakeet(modelDir: Parakeet.configuredModelDir)
    let t1 = Date()
    let text = try model.transcribe(Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))))
    print(text)
    print(String(format: "load %.2fs, transcribe %.2fs, audio %.1fs", t1.timeIntervalSince(t0), Date().timeIntervalSince(t1), Double(out.frameLength) / 16_000))
    exit(0)
}

enum Mode { case dictate, compose }

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Hold to talk, or tap once for hands-free and tap again to finish.
    // Right Option = dictate, Right Command = compose with Haiku.
    static let keys: [UInt16: (Mode, NSEvent.ModifierFlags)] = [
        61: (.dictate, .option),
        54: (.compose, .command),
    ]
    static let tapThreshold: TimeInterval = 0.3

    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private let recorder = Recorder()
    private var parakeet: Parakeet?
    private let work = DispatchQueue(label: "bensvoice.work", qos: .userInitiated)

    private var recording: Mode?
    private var handsFree = false
    private var pressedAt = Date()
    private var keyHeld = false
    private var selection: String?
    private var targetApp: NSRunningApplication?
    private var busy = false

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("waveform")
        buildMenu()

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            installMonitors()
        } else {
            // Global key monitors only deliver events once trusted, so wait for the grant.
            setIcon("exclamationmark.triangle")
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.installMonitors()
                self?.setIcon("waveform")
                self?.setStatus(self?.parakeet == nil ? "Loading Parakeet…" : "Ready")
            }
        }

        loadModel()
    }

    private func installMonitors() {
        NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in self?.handle(e) }
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in self?.handle(e); return e }
    }

    private func loadModel() {
        setStatus(AXIsProcessTrusted() ? "Loading Parakeet…" : "Needs Accessibility permission")
        work.async { [weak self] in
            do {
                let p = try Parakeet(modelDir: Parakeet.configuredModelDir)
                p.warmUp()
                DispatchQueue.main.async {
                    self?.parakeet = p
                    self?.setStatus(AXIsProcessTrusted() ? "Ready" : "Needs Accessibility permission")
                }
            } catch {
                DispatchQueue.main.async { self?.setStatus("Model failed: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: Hotkeys

    private func handle(_ e: NSEvent) {
        if e.type == .keyDown {
            if e.keyCode == 53, recording != nil { cancel(); return } // Esc
            // Another key while holding the modifier means it's a shortcut, not dictation.
            if recording != nil, keyHeld, !handsFree { cancel() }
            return
        }
        guard let (mode, flag) = Self.keys[e.keyCode] else { return }
        let down = e.modifierFlags.contains(flag)
        if down {
            keyHeld = true
            if let current = recording {
                if handsFree && current == mode { finish() }
            } else if !busy {
                begin(mode)
            }
        } else {
            keyHeld = false
            guard recording == mode, !handsFree else { return }
            if Date().timeIntervalSince(pressedAt) < Self.tapThreshold {
                handsFree = true
                setStatus(mode == .dictate ? "Dictating (tap ⌥ to finish)" : "Composing (tap ⌘ to finish)")
            } else {
                finish()
            }
        }
    }

    private func begin(_ mode: Mode) {
        guard parakeet != nil else { NSSound.beep(); return }
        targetApp = NSWorkspace.shared.frontmostApplication
        selection = mode == .compose ? TextInsertion.selectedText() : nil
        do { try recorder.start() } catch { setStatus("Mic error: \(error.localizedDescription)"); return }
        recording = mode
        handsFree = false
        pressedAt = Date()
        NSSound(named: "Tink")?.play()
        setIcon(mode == .dictate ? "mic.fill" : "sparkles")
        setStatus(mode == .dictate ? "Dictating…" : "Composing…")
    }

    private func cancel() {
        _ = recorder.stop()
        recording = nil
        handsFree = false
        setIcon("waveform")
        setStatus("Cancelled")
    }

    private func finish() {
        guard let mode = recording, let parakeet else { return }
        let audio = recorder.stop()
        recording = nil
        handsFree = false
        busy = true
        NSSound(named: "Pop")?.play()
        startSpinner()
        setStatus(mode == .dictate ? "Transcribing…" : "Thinking…")
        let selection = self.selection, appName = targetApp?.localizedName

        work.async { [weak self] in
            var output: String?
            var error: Error?
            do {
                let text = try parakeet.transcribe(audio)
                if !text.isEmpty {
                    output = mode == .dictate ? text : try Composer.compose(instruction: text, selectedText: selection, appName: appName)
                }
            } catch let e { error = e }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.setIcon("waveform")
                if let error { self.setStatus("Error: \(error.localizedDescription)"); NSSound.beep(); return }
                guard let output, !output.isEmpty else { self.setStatus("Heard nothing"); return }
                TextInsertion.insert(output)
                self.setStatus("Ready")
            }
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        for line in ["Hold Right ⌥ — dictate", "Hold Right ⌘ — compose with Haiku", "Quick tap = hands-free, Esc = cancel"] {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let quit = NSMenuItem(title: "Quit BensVoice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc private func toggleLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { setStatus("Login item: \(error.localizedDescription)") }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func setIcon(_ symbol: String) {
        spinner?.invalidate()
        spinner = nil
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "BensVoice")
    }

    private var spinner: Timer?

    /// Rotating arc in the menu bar while transcribing / waiting on Haiku.
    private func startSpinner() {
        spinner?.invalidate()
        var angle: CGFloat = 0
        let draw = { [weak self] in
            let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
                let path = NSBezierPath()
                path.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: 6.5,
                               startAngle: angle, endAngle: angle + 270, clockwise: false)
                path.lineWidth = 2
                path.lineCapStyle = .round
                NSColor.black.setStroke()
                path.stroke()
                return true
            }
            image.isTemplate = true
            self?.statusItem.button?.image = image
            angle -= 30
        }
        draw()
        spinner = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { _ in draw() }
        RunLoop.main.add(spinner!, forMode: .common) // keep spinning while the menu is open
    }

    private func setStatus(_ text: String) {
        statusLine.title = text
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

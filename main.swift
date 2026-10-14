// MicHold: records while the microphone (Dictation) key or the space bar is held, transcribes with
// whisper.cpp on release, and pastes the text at the cursor. A short press of the mic key opens Siri.
// It has no window.
import AppKit
import AVFoundation
import ApplicationServices

let triggerKeyCodes: Set<Int64> = [96, 176]  // same physical key as F5 (microphone / Dictation)
let spaceKeyCode: Int64 = 49
let backspaceKeyCode: CGKeyCode = 51

let holdThreshold: TimeInterval = 0.3
let minIntervalAfterKeyUp: TimeInterval = 0.15
let configCandidates = ["~/.config/michold/config.json", "~/.config/qd/voice.json"].map { NSString(string: $0).expandingTildeInPath }
let configPath = configCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? configCandidates[0]
let logPath = NSString(string: "~/Library/Logs/MicHold.log").expandingTildeInPath

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

struct Config: Decodable {
    let serverBin: String
    let model: String
    let language: String?
    let triggers: [String]?       // "micKey" / "space" (both by default)
    let spaceHoldSeconds: Double? // hold time for the space bar (default 0.5 s)
    let chunkSoftSeconds: Double? // split at the next pause after this long (default 20 s)
    let chunkHardSeconds: Double? // split even without a pause (default 45 s)
    let pauseLevelDb: Float?      // input below this level counts as a pause (default -42 dB)
    let silenceLevelDb: Float?    // pieces that never exceed this level are not transcribed (default -48 dB)
}

// whisper-server starts when recording starts and stops after transcription (it is not kept running).
final class WhisperServer {
    let cfg: Config
    private var proc: Process?
    private var port = 0

    init(cfg: Config) { self.cfg = cfg }

    func start() {
        stop()
        port = Self.freePort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cfg.serverBin)
        p.arguments = ["-m", cfg.model, "--host", "127.0.0.1", "--port", String(port), "-l", cfg.language ?? "ja"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); proc = p } catch { log("failed to start whisper-server: \(error)") }
    }

    func stop() {
        guard let p = proc else { return }
        proc = nil
        if p.isRunning { p.terminate() }
    }

    func transcribe(wav: URL) -> String? {
        guard proc != nil, waitReady(timeout: 90) else { log("whisper-server did not become ready"); return nil }
        guard let audio = try? Data(contentsOf: wav) else { return nil }
        let boundary = "----michold\(Int(Date().timeIntervalSince1970 * 1000))"
        var body = Data()
        func field(_ k: String, _ v: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        field("response_format", "text")
        field("language", cfg.language ?? "ja")
        field("temperature", "0.0")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, code) = Self.send(req), code == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func waitReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 1
        while Date() < deadline {
            if let (_, code) = Self.send(req), code == 200 { return true }
            guard proc?.isRunning == true else { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func send(_ req: URLRequest) -> (Data, Int)? {
        let sem = DispatchSemaphore(value: 0)
        var result: (Data, Int)?
        URLSession.shared.dataTask(with: req) { data, res, _ in
            if let data = data, let http = res as? HTTPURLResponse { result = (data, http.statusCode) }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

final class Recorder {
    private var recorder: AVAudioRecorder?
    private var index = 0
    private(set) var url = FileManager.default.temporaryDirectory.appendingPathComponent("michold-0.wav")

    var elapsed: TimeInterval { recorder?.currentTime ?? 0 }

    var level: Float {
        guard let r = recorder else { return -160 }
        r.updateMeters()
        return r.averagePower(forChannel: 0)
    }

    func start() -> Bool {
        index += 1
        url = FileManager.default.temporaryDirectory.appendingPathComponent("michold-\(index).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else {
            log("failed to start recording")
            return false
        }
        r.isMeteringEnabled = true
        guard r.record() else {
            log("failed to start recording")
            return false
        }
        recorder = r
        return true
    }

    // Stops the current file and returns it.
    func stop() -> URL {
        recorder?.stop()
        recorder = nil
        return url
    }
}

// Whisper returns one line per phrase; joining them keeps pasted text on a single line.
func flatten(_ text: String, language: String?) -> String {
    let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let cjk = ["ja", "zh"].contains(language ?? "ja")
    let enders = CharacterSet(charactersIn: "。、！？!?.,，")
    var out = ""
    for line in lines {
        if out.isEmpty { out = line; continue }
        let ended = out.unicodeScalars.last.map { enders.contains($0) } ?? false
        out += (cjk ? (ended ? "" : "、") : " ") + line
    }
    return out
}

enum Paster {
    static func backspace() {
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: src, virtualKey: backspaceKeyCode, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: backspaceKeyCode, keyDown: false)?.post(tap: .cghidEventTap)
    }

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let changeCount = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard pb.changeCount == changeCount else { return }
            pb.clearContents()
            let items: [NSPasteboardItem] = saved.map { d in
                let item = NSPasteboardItem()
                for (t, v) in d { item.setData(v, forType: t) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }
}

final class MicHold {
    enum State { case idle, pressing, holding, transcribing }
    enum Source { case micKey, space }

    private var state = State.idle
    private var source = Source.micKey
    private var holdWork: DispatchWorkItem?
    private var lastKeyUpAt: Date?
    private var tap: CFMachPort?
    private let recorder = Recorder()
    private let server: WhisperServer
    private let work = DispatchQueue(label: "michold.transcribe")

    private let micKeyEnabled: Bool
    private let spaceEnabled: Bool
    private let spaceHoldSeconds: TimeInterval
    private let language: String?
    private let chunkSoft: TimeInterval
    private let chunkHard: TimeInterval
    private let pauseLevel: Float
    private let silenceLevel: Float
    private var chunkTimer: Timer?
    private var pending = 0
    private var quietSince: Date?
    private var chunkPeak: Float = -160
    private var needsJoin = false
    private var pastedAny = false

    init(cfg: Config) {
        server = WhisperServer(cfg: cfg)
        let triggers = cfg.triggers ?? ["micKey", "space"]
        micKeyEnabled = triggers.contains("micKey")
        spaceEnabled = triggers.contains("space")
        spaceHoldSeconds = cfg.spaceHoldSeconds ?? 0.5
        language = cfg.language
        chunkSoft = cfg.chunkSoftSeconds ?? 20
        chunkHard = cfg.chunkHardSeconds ?? 45
        pauseLevel = cfg.pauseLevelDb ?? -42
        silenceLevel = cfg.silenceLevelDb ?? -48
    }

    func start() {
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else {
            log("waiting for the Accessibility permission")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start() }
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { ok in if !ok { log("microphone permission denied") } }

        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        guard let t = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<MicHold>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log("could not create the event tap")
            return
        }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        log("started")
    }

    // Events for which this returns true are swallowed (so macOS Dictation and Siri are not triggered)
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return false
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let isDown = type == .keyDown
        let repeating = isDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if key == spaceKeyCode {
            guard spaceEnabled, event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else { return false }
            if isDown {
                if repeating { return source == .space && state != .idle }
                keyDown(.space, threshold: spaceHoldSeconds)
            } else {
                keyUp(.space)
            }
            return false  // the first space is passed through; it is removed with Backspace once recording starts
        }
        guard micKeyEnabled, triggerKeyCodes.contains(key) else { return false }
        if isDown {
            if !repeating { keyDown(.micKey, threshold: holdThreshold) }
        } else {
            keyUp(.micKey)
        }
        return true
    }

    private func keyDown(_ from: Source, threshold: TimeInterval) {
        guard state == .idle else { return }
        if let last = lastKeyUpAt, Date().timeIntervalSince(last) < minIntervalAfterKeyUp { return }
        source = from
        state = .pressing
        let w = DispatchWorkItem { [weak self] in self?.beginRecording() }
        holdWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + threshold, execute: w)
    }

    private func keyUp(_ from: Source) {
        guard from == source else { return }
        lastKeyUpAt = Date()
        switch state {
        case .pressing:
            holdWork?.cancel()
            state = .idle
            if from == .micKey { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Siri.app")) }
        case .holding:
            endRecording()
        default:
            break
        }
    }

    private func beginRecording() {
        guard state == .pressing else { return }
        if source == .space { Paster.backspace() }  // remove the space typed before the hold
        server.start()  // load the model while the user is speaking
        guard recorder.start() else { server.stop(); state = .idle; return }
        state = .holding
        needsJoin = false
        pastedAny = false
        quietSince = nil
        chunkPeak = -160
        chunkTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        NSSound(named: "Tink")?.play()
    }

    // Long recordings are cut at a pause (or at the hard limit) and each piece is pasted as soon as it is transcribed.
    private func tick() {
        guard state == .holding else { return }
        let level = recorder.level
        chunkPeak = max(chunkPeak, level)
        if level < pauseLevel { quietSince = quietSince ?? Date() } else { quietSince = nil }
        let elapsed = recorder.elapsed
        let paused = quietSince.map { Date().timeIntervalSince($0) >= 0.5 } ?? false
        guard elapsed >= chunkHard || (elapsed >= chunkSoft && paused) else { return }
        let wav = recorder.stop()
        let silent = chunkPeak < silenceLevel
        chunkPeak = -160
        quietSince = nil
        let restarted = recorder.start()
        enqueue(wav, silent: silent)
        if !restarted {
            chunkTimer?.invalidate()
            chunkTimer = nil
            state = .transcribing
        }
    }

    private func endRecording() {
        chunkTimer?.invalidate()
        chunkTimer = nil
        chunkPeak = max(chunkPeak, recorder.level)
        let wav = recorder.stop()
        state = .transcribing
        NSSound(named: "Pop")?.play()
        enqueue(wav, silent: chunkPeak < silenceLevel)
    }

    private func enqueue(_ wav: URL, silent: Bool) {
        pending += 1
        work.async { [server, language] in
            let raw = silent ? "" : (server.transcribe(wav: wav) ?? "")
            try? FileManager.default.removeItem(at: wav)
            let text = flatten(raw, language: language)
            DispatchQueue.main.async {
                self.pending -= 1
                if text.isEmpty {
                    if self.state == .transcribing && self.pending == 0 && !self.pastedAny { NSSound(named: "Basso")?.play() }
                } else {
                    let cjk = ["ja", "zh"].contains(language ?? "ja")
                    let joiner = self.needsJoin ? (cjk ? "、" : " ") : ""
                    Paster.paste(joiner + text)
                    self.pastedAny = true
                    self.needsJoin = !(text.unicodeScalars.last.map { CharacterSet(charactersIn: "。、！？!?.,，").contains($0) } ?? true)
                }
                self.finish()
            }
        }
    }

    private func finish() {
        guard state == .transcribing, pending == 0 else { return }
        server.stop()
        state = .idle
    }
}

guard let data = FileManager.default.contents(atPath: configPath),
      let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
    log("config file not found: \(configPath)")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let micHold = MicHold(cfg: cfg)
micHold.start()
app.run()

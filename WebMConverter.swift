import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Turkish when the system language is Turkish, English otherwise.
let isTurkish = Locale.preferredLanguages.first?.hasPrefix("tr") ?? false
func t(_ tr: String, _ en: String) -> String { isTurkish ? tr : en }
func percent(_ n: Int) -> String { isTurkish ? "%\(n)" : "\(n)%" }

enum Status {
    case waiting
    case working(Int)
    case ok(String)
    case error(String)

    var text: String {
        switch self {
        case .waiting: t("Bekliyor", "Waiting")
        case .working(let p): t("Dönüştürülüyor ", "Converting ") + percent(p)
        case .ok(let s): "✓ " + s
        case .error(let s): t("Hata: ", "Error: ") + s
        }
    }

    var finished: Bool {
        switch self {
        case .ok, .error: true
        default: false
        }
    }

    var color: Color {
        switch self {
        case .waiting: .secondary
        case .working: .accentColor
        case .ok: .green
        case .error: .red
        }
    }
}

struct Item: Identifiable {
    let id = UUID()
    let url: URL
    var status: Status = .waiting
}

// Holds the running ffmpeg process so the Cancel button can stop it from the main thread.
final class Runner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var _cancelled = false

    var cancelled: Bool { lock.withLock { _cancelled } }

    func reset() { lock.withLock { _cancelled = false; process = nil } }
    func set(_ p: Process?) { lock.withLock { process = p } }
    func cancel() {
        lock.withLock {
            _cancelled = true
            process?.terminate()
        }
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var items: [Item] = []
    @Published var quality: Double = 75
    @Published var scale = 100
    @Published var target: URL?
    @Published var running = false
    @Published var done = 0

    let runner = Runner()

    static let exts: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "3gp", "ts", "mts", "m2ts", "gif"]
    static let scales = Array(stride(from: 100, through: 10, by: -10))

    var ffmpeg: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func add(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                add(files)
            } else if Self.exts.contains(url.pathExtension.lowercased()), !items.contains(where: { $0.url == url }) {
                items.append(Item(url: url))
            }
        }
    }

    func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = [.movie, .gif]
        if p.runModal() == .OK { add(p.urls) }
    }

    func pickTarget() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = t("Seç", "Choose")
        if p.runModal() == .OK { target = p.url }
    }

    func convert() {
        guard let target, let ffmpeg else { return }
        running = true
        done = 0
        runner.reset()
        // VP9 CRF: 0 is best, 63 is worst. Quality 75 → CRF 27.
        let crf = 63 - Int(quality * 0.48)
        let s = scale
        let runner = runner
        let jobs = items.enumerated().map { ($0.offset, $0.element.url) }
        for i in items.indices { items[i].status = .waiting }
        // ffmpeg already uses all cores, so videos are converted one at a time.
        Task.detached {
            for (idx, url) in jobs {
                if runner.cancelled { break }
                let r = await Self.convertOne(url: url, target: target, crf: crf, scale: s, ffmpeg: ffmpeg, runner: runner) { p in
                    Task { @MainActor in
                        // A late progress update must not overwrite the final result.
                        if !self.items[idx].status.finished { self.items[idx].status = .working(p) }
                    }
                }
                await MainActor.run {
                    self.items[idx].status = r
                    self.done += 1
                }
            }
            await MainActor.run {
                for i in self.items.indices {
                    if case .working = self.items[i].status { self.items[i].status = .waiting }
                }
                self.running = false
            }
        }
    }

    func cancel() { runner.cancel() }

    struct Probe {
        var duration: Double
        var videoBitrate: Double?  // bits per second
        var audioBitrate: Double?
        var width = 0  // as displayed, after rotation
        var height = 0
    }

    nonisolated static func probe(_ url: URL, ffmpeg: String) -> Probe? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe")
        p.arguments = ["-v", "error", "-show_entries", "format=duration,bit_rate:stream=codec_type,bit_rate,width,height:stream_side_data=rotation", "-of", "json", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = json["format"] as? [String: Any],
              let duration = Double(format["duration"] as? String ?? "") else { return nil }
        let streams = json["streams"] as? [[String: Any]] ?? []
        func rate(_ type: String) -> Double? {
            streams.first { $0["codec_type"] as? String == type }.flatMap { Double($0["bit_rate"] as? String ?? "") }
        }
        let audio = rate("audio")
        // MKV and some other containers only report the total bitrate.
        var video = rate("video")
        if video == nil, let total = Double(format["bit_rate"] as? String ?? "") { video = total - (audio ?? 0) }
        var info = Probe(duration: duration, videoBitrate: video, audioBitrate: audio)
        if let v = streams.first(where: { $0["codec_type"] as? String == "video" }) {
            let w = v["width"] as? Int ?? 0, h = v["height"] as? Int ?? 0
            let rotation = (v["side_data_list"] as? [[String: Any]])?.compactMap { $0["rotation"] as? Int }.first ?? 0
            (info.width, info.height) = abs(rotation) % 180 == 90 ? (h, w) : (w, h)
        }
        return info
    }

    nonisolated static func convertOne(url: URL, target: URL, crf: Int, scale: Int, ffmpeg: String, runner: Runner,
                                       progress: @escaping @Sendable (Int) -> Void) async -> Status {
        var out = target.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".webm")
        var n = 1
        while FileManager.default.fileExists(atPath: out.path) {
            out = target.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-\(n).webm")
            n += 1
        }
        // Real video files always report a duration; without one ffmpeg may "decode" garbage into an empty file.
        guard let info = probe(url, ffmpeg: ffmpeg), info.duration > 0 else { return .error(t("okunamadı", "could not read")) }
        let total = info.duration

        // Width and height must be even for VP9 with 4:2:0 chroma.
        let f = Double(scale) / 100
        let vf = "scale=trunc(iw*\(f)/2)*2:trunc(ih*\(f)/2)*2"
        // CRF alone aims for a fixed quality, so an already well-compressed source can grow a lot.
        // Capping the bitrate at the source's (scaled by the pixel count) keeps the output from getting bigger.
        var maxVideo = "0"
        if let v = info.videoBitrate, v > 0 { maxVideo = String(Int(max(v * f * f, 100_000) / 1000)) + "k" }
        let audioKbps = info.audioBitrate.map { min(128, max(32, Int($0 / 1000))) } ?? 128
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error", "-i", url.path,
                       "-vf", vf, "-pix_fmt", "yuv420p",
                       "-c:v", "libvpx-vp9", "-crf", String(crf), "-b:v", maxVideo, "-row-mt", "1", "-deadline", "good", "-cpu-used", "4",
                       "-c:a", "libopus", "-b:a", "\(audioKbps)k",
                       "-progress", "pipe:1", out.path]
        let stdout = Pipe()
        let errLog = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: errLog.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errLog) }
        p.standardOutput = stdout
        p.standardError = try? FileHandle(forWritingTo: errLog)

        do { try p.run() } catch { return .error(t("ffmpeg çalışmadı", "ffmpeg failed to run")) }
        runner.set(p)
        defer { runner.set(nil) }

        var last = -1
        do {
            for try await line in stdout.fileHandleForReading.bytes.lines where line.hasPrefix("out_time_us=") {
                guard let us = Double(line.dropFirst("out_time_us=".count)) else { continue }
                let pct = min(99, max(0, Int(us / 1_000_000 / total * 100)))
                if pct != last { last = pct; progress(pct) }
            }
        } catch {}
        p.waitUntilExit()

        if runner.cancelled {
            try? FileManager.default.removeItem(at: out)
            return .error(t("iptal edildi", "cancelled"))
        }
        guard p.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: out)
            let log = (try? String(contentsOf: errLog, encoding: .utf8)) ?? ""
            let msg = log.split(separator: "\n").last.map(String.init) ?? t("dönüştürülemedi", "conversion failed")
            return .error(msg)
        }
        let before = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let fmt = ByteCountFormatter()
        let sizes = "\(fmt.string(fromByteCount: Int64(before))) → \(fmt.string(fromByteCount: Int64(after)))"
        let from = "\(info.width)×\(info.height)"
        let res = probe(out, ffmpeg: ffmpeg).map { "\($0.width)×\($0.height)" } ?? from
        return .ok((res == from ? res : "\(from) → \(res)") + " · " + sizes)
    }
}

struct ContentView: View {
    @StateObject var m = Model()
    @State var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if m.ffmpeg == nil {
                Text(t("ffmpeg bulunamadı. Terminalde çalıştırın: brew install ffmpeg", "ffmpeg not found. Run in Terminal: brew install ffmpeg")).foregroundStyle(.red)
            }
            HStack {
                Button(t("Video Ekle…", "Add Videos…")) { m.pickFiles() }
                Button(t("Listeyi Temizle", "Clear List")) { m.items.removeAll() }.disabled(m.items.isEmpty || m.running)
                Spacer()
                Text("\(m.items.count) " + t("dosya", m.items.count == 1 ? "file" : "files")).foregroundStyle(.secondary)
            }
            List {
                ForEach(m.items) { item in
                    HStack {
                        Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(item.status.text).foregroundStyle(item.status.color)
                    }
                }
                .onDelete { if !m.running { m.items.remove(atOffsets: $0) } }
            }
            .overlay {
                if m.items.isEmpty {
                    Text(t("Videoları ya da klasörleri buraya sürükleyin", "Drag videos or folders here")).foregroundStyle(.secondary)
                }
            }
            .border(hover ? Color.accentColor : .clear, width: 2)
            .onDrop(of: [.fileURL], isTargeted: $hover) { providers in
                guard !m.running else { return false }
                for pr in providers {
                    _ = pr.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in m.add([url]) } }
                    }
                }
                return true
            }
            HStack {
                Text(t("Kalite", "Quality") + ": \(Int(m.quality))").frame(width: 90, alignment: .leading)
                Slider(value: $m.quality, in: 1...100, step: 1)
            }
            .disabled(m.running)
            HStack {
                Text(t("Çözünürlük", "Resolution")).frame(width: 90, alignment: .leading)
                Picker("", selection: $m.scale) {
                    ForEach(Model.scales, id: \.self) { s in
                        Text(s == 100 ? percent(s) + t(" (orijinal)", " (original)") : percent(s)).tag(s)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .disabled(m.running)
            HStack {
                Button(t("Hedef Klasör…", "Output Folder…")) { m.pickTarget() }.disabled(m.running)
                Text(m.target?.path ?? t("Seçilmedi", "Not selected")).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                if let folder = m.target {
                    Button(t("Finder'da Aç", "Show in Finder")) { NSWorkspace.shared.open(folder) }
                }
            }
            HStack {
                if m.running {
                    ProgressView(value: Double(m.done), total: Double(max(m.items.count, 1)))
                    Button(t("İptal", "Cancel")) { m.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Spacer()
                }
                Button(t("WebM'e Çevir", "Convert to WebM")) { m.convert() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(m.items.isEmpty || m.target == nil || m.running || m.ffmpeg == nil)
            }
            HStack {
                Spacer()
                Link("© 2026 Murat Gökoğlu · muratgokoglu.com", destination: URL(string: "https://muratgokoglu.com")!)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 500)
    }
}

@main
struct WebMConverterApp: App {
    var body: some Scene {
        WindowGroup(t("WebM Dönüştürücü", "WebM Converter")) { ContentView() }
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button(t("WebM Dönüştürücü Hakkında", "About WebM Converter")) {
                        NSApplication.shared.orderFrontStandardAboutPanel(options: [
                            .credits: NSAttributedString(string: t("Yayıncı", "Publisher") + ": Murat Gökoğlu\nmuratgokoglu.com"),
                        ])
                    }
                }
            }
    }
}

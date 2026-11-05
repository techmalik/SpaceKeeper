import Cocoa
import SwiftUI

// MARK: - Sending

enum FeedbackKind: String, CaseIterable, Identifiable {
    case idea = "Idea", bug = "Bug", question = "Question", other = "Other"
    var id: String { rawValue }
}

enum FeedbackError: LocalizedError {
    case server(String)
    var errorDescription: String? { if case .server(let m) = self { return m }; return nil }
}

enum FeedbackSender {
    /// Posts the feedback (and an optional screenshot) to the forwarding service, which emails it to the author.
    static func send(kind: FeedbackKind, message: String, replyTo: String, includeSystemInfo: Bool, screenshot: Data?) async throws {
        let boundary = "SpaceKeeper-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        func field(_ name: String, _ value: String) {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("_subject", "SpaceKeeper feedback: \(kind.rawValue)")
        field("_captcha", "false")
        field("_template", "table")
        field("_honey", "")                                   // spam trap, must stay empty
        field("Type", kind.rawValue)
        field("Message", message)
        if !replyTo.isEmpty { field("email", replyTo) }       // becomes the Reply-To address
        if includeSystemInfo {
            field("SpaceKeeper", "\(AppInfo.version) (\(AppInfo.build))")
            field("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        }
        if let screenshot {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"attachment\"; filename=\"screenshot.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
            body.append(screenshot)
            add("\r\n")
        }
        add("--\(boundary)--\r\n")

        var req = URLRequest(url: AppInfo.feedbackEndpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.upload(for: req, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FeedbackError.server("The feedback service returned an error. Please try again.")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let ok = (json["success"] as? Bool) ?? ((json["success"] as? String) == "true")
            if !ok { throw FeedbackError.server((json["message"] as? String) ?? "The feedback service rejected the message.") }
        }
    }

    /// Downscales and compresses an image so it stays well under email attachment limits.
    static func jpegData(from image: NSImage, maxSide: CGFloat = 1800) -> Data? {
        guard let rep = image.representations.first else { return nil }
        let w = CGFloat(rep.pixelsWide > 0 ? rep.pixelsWide : Int(image.size.width))
        let h = CGFloat(rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(image.size.height))
        let scale = min(1, maxSide / max(w, h))
        let size = NSSize(width: max(1, w * scale), height: max(1, h * scale))
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return out.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

// MARK: - UI

final class FeedbackModel: ObservableObject {
    @Published var kind: FeedbackKind = .idea
    @Published var message = ""
    @Published var email = ""
    @Published var includeSystemInfo = true
    @Published var screenshot: Data?
    @Published var screenshotName = ""
    @Published var sending = false
    @Published var status = ""
    @Published var failed = false
    var onTakeScreenshot: () -> Void = {}
    var onChooseFile: () -> Void = {}

    var canSend: Bool { !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending }

    @MainActor func send() {
        sending = true; failed = false; status = ""
        let (k, m, e, i, s) = (kind, message, email.trimmingCharacters(in: .whitespaces), includeSystemInfo, screenshot)
        Task { @MainActor in
            do {
                try await FeedbackSender.send(kind: k, message: m, replyTo: e, includeSystemInfo: i, screenshot: s)
                status = "Thank you! Your feedback was sent."
                message = ""; screenshot = nil; screenshotName = ""
            } catch {
                failed = true
                status = "Couldn't send it: \(error.localizedDescription)"
            }
            sending = false
        }
    }
}

private struct FeedbackView: View {
    @ObservedObject var model: FeedbackModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send Feedback").font(.system(size: 18, weight: .bold))
            Text("Tell me what's working, what's broken, or what you'd like to see. It goes straight to my inbox.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $model.kind) {
                ForEach(FeedbackKind.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()

            TextEditor(text: $model.message)
                .font(.system(size: 13))
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))

            TextField("Your email (optional — only if you'd like a reply)", text: $model.email)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button("Take Screenshot…") { model.onTakeScreenshot() }
                Button("Attach Image…") { model.onChooseFile() }
                if model.screenshot != nil {
                    Text(model.screenshotName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Button { model.screenshot = nil; model.screenshotName = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("Remove attachment")
                }
                Spacer()
            }

            Toggle("Include SpaceKeeper and macOS version", isOn: $model.includeSystemInfo)
                .font(.system(size: 12))

            HStack {
                if model.sending { ProgressView().controlSize(.small) }
                Text(model.status)
                    .font(.system(size: 12))
                    .foregroundStyle(model.failed ? Color.red : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if model.failed {
                    Button("Email Instead") { NSWorkspace.shared.open(AppInfo.feedbackURL) }
                }
                Button("Send") { model.send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSend)
            }

            Text("Sent over HTTPS via formsubmit.co to \(AppInfo.author). Nothing else is collected, and nothing is sent unless you press Send.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 460)
    }
}

final class FeedbackWindowController {
    static let shared = FeedbackWindowController()
    private let model = FeedbackModel()
    private var window: NSWindow?

    func show() {
        if window == nil {
            model.onTakeScreenshot = { [weak self] in self?.takeScreenshot() }
            model.onChooseFile = { [weak self] in self?.chooseFile() }
            let w = NSWindow(contentViewController: NSHostingController(rootView: FeedbackView(model: model)))
            w.title = "Send Feedback"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        model.status = ""; model.failed = false
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func attach(_ image: NSImage, name: String) {
        guard let data = FeedbackSender.jpegData(from: image) else { return }
        model.screenshot = data
        model.screenshotName = name
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .gif, .tiff]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window ?? NSWindow()) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let img = NSImage(contentsOf: url) else { return }
            self?.attach(img, name: url.lastPathComponent)
        }
    }

    /// macOS's own interactive screenshot tool (drag to select an area, Esc to cancel).
    private func takeScreenshot() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spacekeeper-feedback-\(UUID().uuidString).png")
        window?.orderOut(nil)
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-i", "-x", tmp.path]
            try? p.run(); p.waitUntilExit()
            DispatchQueue.main.async {
                if let img = NSImage(contentsOf: tmp) { self.attach(img, name: "screenshot.jpg") }
                try? FileManager.default.removeItem(at: tmp)
                NSApp.activate(ignoringOtherApps: true)
                self.window?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

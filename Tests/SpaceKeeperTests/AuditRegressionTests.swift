import Cocoa

// Standalone regression runner: uses the same system-only toolchain as the app.
@main
struct AuditRegressionTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                       file: StaticString = #file, line: UInt = #line) {
        precondition(condition(), message, file: file, line: line)
    }

    static func display(current: Int = 10) -> DisplaySpaces {
        DisplaySpaces(uuid: "test", current: current, spaces: [
            SpaceInfo(id: 10, type: 0), SpaceInfo(id: 11, type: 4),
            SpaceInfo(id: 12, type: 0), SpaceInfo(id: 13, type: 4), SpaceInfo(id: 14, type: 0)
        ])
    }

    static func validate(_ body: String, status: Int = 200) throws {
        let response = HTTPURLResponse(url: URL(string: "https://example.invalid")!,
                                       statusCode: status, httpVersion: nil, headerFields: nil)!
        try FeedbackSender.validateResponse(data: Data(body.utf8), response: response)
    }

    @MainActor static func main() async throws {
        expect(display().destinationIndex(relative: 1) == 2, "Skip full-screen destination going right")
        expect(display(current: 14).destinationIndex(relative: -1) == 2, "Skip full-screen destination going left")
        for (number, index) in [(1, 0), (2, 2), (3, 4)] {
            expect(display().destinationIndex(desktop: number) == index, "Absolute desktop numbering")
        }
        expect(display().destinationIndex(relative: -1) == nil, "First desktop boundary")
        expect(display(current: 14).destinationIndex(relative: 1) == nil, "Last desktop boundary")
        expect(display(current: 14).destinationIndex(relative: Int.max) == nil, "Overflow")
        expect(display().destinationIndex(relative: Int.min) == nil, "Underflow")
        expect(display().destinationIndex(desktop: 0) == nil, "Invalid desktop zero")
        expect(display().destinationIndex(desktop: 4) == nil, "Missing desktop")
        expect(display(current: 11).destinationIndex(desktop: 1) == nil, "Full-screen source")
        expect(DisplaySpaces(uuid: "empty", current: 0, spaces: []).destinationIndex() == nil, "No displays")
        print("PASS: desktop destinations and boundaries")

        let start = CGRect(x: 100, y: 100, width: 500, height: 400)
        expect(!WindowMover.didFollowDrag(from: nil, to: start), "Missing initial frame must not confirm drag")
        expect(!WindowMover.didFollowDrag(from: start, to: nil), "Missing current frame must not confirm drag")
        expect(!WindowMover.didFollowDrag(from: start, to: start), "Unmoved window")
        expect(WindowMover.didFollowDrag(from: start, to: start.offsetBy(dx: 60, dy: 0)), "Verified drag")
        print("PASS: drag verification fails closed")

        await WindowMover.shared.switchSpaces(by: Int.min)
        await WindowMover.shared.switchSpaces(by: Int.max)
        for duration in [-1.0, .nan, .infinity, Double.greatestFiniteMagnitude] {
            await WindowMover.shared.sleep(duration)
        }
        print("PASS: invalid debug movement arguments do not crash or generate input")

        try validate(#"{"success":true}"#)
        try validate(#"{"success":"true"}"#)
        for (body, status) in [("", 200), ("<html>Activate your form</html>", 200), ("[]", 200), ("{}", 200),
                               (#"{"success":false}"#, 200), (#"{"success":"false"}"#, 200),
                               (#"{"success":true}"#, 500), ("", 204)] {
            do { try validate(body, status: status); preconditionFailure("Accepted invalid response: \(body)") }
            catch { /* Expected rejection. */ }
        }
        do {
            try validate(#"{"success":false,"message":"Please activate the form"}"#)
            preconditionFailure("Accepted rejection")
        } catch { expect(error.localizedDescription == "Please activate the form", "Preserve service error") }
        print("PASS: feedback acknowledgements and errors")

        expect(DockPreviewController.previewWidth(count: 0, availableWidth: 1440) == 240, "Empty preview")
        expect(DockPreviewController.previewWidth(count: 2, availableWidth: 1440) == 434, "Two windows")
        expect(DockPreviewController.previewWidth(count: 20, availableWidth: 1440) == 1416, "Overflow windows")
        expect(DockPreviewController.previewWidth(count: 20, availableWidth: 0) > 0, "Tiny display")
        print("PASS: preview width constraints")

        var requests = 0
        var model: FeedbackModel!
        model = FeedbackModel { _, message, _, _, screenshot in
            requests += 1
            expect(message == "original", "Send snapshot")
            expect(screenshot == Data([1]), "Send attachment snapshot")
            model.message = "new draft"
            model.screenshot = Data([2])
            model.screenshotName = "new.png"
        }
        model.message = " \n "
        model.send()
        expect(!model.sending && requests == 0, "Reject empty submission")
        model.message = "original"
        model.screenshot = Data([1])
        model.send()
        model.send()
        for _ in 0..<100 where model.sending { try await Task.sleep(nanoseconds: 1_000_000) }
        expect(!model.sending && requests == 1, "Reject concurrent duplicate submission")
        expect(model.message == "new draft" && model.screenshot == Data([2]), "Keep edits made during send")
        expect(model.screenshotName == "new.png", "Keep new attachment name")
        print("PASS: in-flight feedback edits and duplicate sends")

        let failed = FeedbackModel { _, _, _, _, _ in throw FeedbackError.server("offline") }
        failed.message = "keep me"; failed.screenshot = Data([3])
        failed.send()
        for _ in 0..<100 where failed.sending { try await Task.sleep(nanoseconds: 1_000_000) }
        expect(failed.failed && failed.message == "keep me" && failed.screenshot == Data([3]), "Preserve failed draft")
        print("PASS: failed feedback preserves draft")
        // Return travel after a move counts from where the display actually is.
        expect(WindowMover.returnSteps(currentIndex: 4, origin: 0, expected: 4) == 4, "Return after full move")
        expect(WindowMover.returnSteps(currentIndex: 2, origin: 0, expected: 4) == 2, "Return after a dropped key press")
        expect(WindowMover.returnSteps(currentIndex: 0, origin: 0, expected: 4) == 0, "Nothing to return from")
        expect(WindowMover.returnSteps(currentIndex: 1, origin: 3, expected: -2) == -2, "Return after moving left")
        expect(WindowMover.returnSteps(currentIndex: nil, origin: 0, expected: 3) == 3, "Unknown position falls back")
        print("PASS: return travel after a move")

        let ns = DockInspector.Orientation.bottom
        let dock = CGRect(x: 400, y: 1000, width: 600, height: 70)
        expect(!DockInspector.isNear(.zero, listFrame: .zero, orientation: ns, magnificationReach: 0), "Unknown Dock frame is never near")
        expect(!DockInspector.isNear(CGPoint(x: 2, y: 2), listFrame: .zero, orientation: .left, magnificationReach: 64), "No phantom corner Dock")
        expect(DockInspector.isNear(CGPoint(x: 700, y: 1030), listFrame: dock, orientation: ns, magnificationReach: 0), "On the Dock")
        expect(DockInspector.isNear(CGPoint(x: 700, y: 940), listFrame: dock, orientation: ns, magnificationReach: 64), "Magnified icon above the Dock")
        expect(!DockInspector.isNear(CGPoint(x: 700, y: 940), listFrame: dock, orientation: ns, magnificationReach: 0), "Above an unmagnified Dock")
        expect(DockInspector.magnificationReach(magnification: false, tileSize: 48, largeSize: 128) == 0, "No magnification")
        expect(DockInspector.magnificationReach(magnification: true, tileSize: 48, largeSize: 128) == 80, "Magnification reach")
        expect(DockInspector.magnificationReach(magnification: true, tileSize: 100, largeSize: 50) == 0, "Large smaller than tile")
        expect(DockInspector.orientation("left") == .left && DockInspector.orientation(nil) == .bottom, "Dock orientation")
        print("PASS: Dock hit region")

        expect(Windows.newWindowRank(title: "New Window", hasSubmenu: true, cmdChar: nil, cmdModifiers: nil) == 0, "Terminal-style submenu")
        expect(Windows.newWindowRank(title: "New Finder Window", hasSubmenu: false, cmdChar: "N", cmdModifiers: 0) == 1, "Finder")
        expect(Windows.newWindowRank(title: "New", hasSubmenu: false, cmdChar: "N", cmdModifiers: 0) == 2, "TextEdit")
        expect(Windows.newWindowRank(title: "New", hasSubmenu: true, cmdChar: nil, cmdModifiers: nil) == nil, "Xcode File › New submenu")
        expect(Windows.newWindowRank(title: "Neues Fenster", hasSubmenu: false, cmdChar: "N", cmdModifiers: 0) == 3, "Localized ⌘N")
        expect(Windows.newWindowRank(title: "Nouvelle fenêtre privée", hasSubmenu: false, cmdChar: "N", cmdModifiers: 1) == nil, "⇧⌘N isn't the plain new item")
        expect(Windows.newWindowRank(title: "Open…", hasSubmenu: false, cmdChar: "O", cmdModifiers: 0) == nil, "Unrelated item")
        print("PASS: new-window menu item selection")
        print("All regression checks passed. No network requests or desktop input were generated.")
    }
}

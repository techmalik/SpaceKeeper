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

        // --- 1.1: cross-display move plans
        let a = DisplaySpaces(uuid: "A", current: 10, spaces: [SpaceInfo(id: 10, type: 0), SpaceInfo(id: 12, type: 0)])
        let b = DisplaySpaces(uuid: "B", current: 21, spaces: [SpaceInfo(id: 20, type: 0), SpaceInfo(id: 21, type: 0), SpaceInfo(id: 22, type: 0)])
        let bFull = DisplaySpaces(uuid: "B", current: 23, spaces: [SpaceInfo(id: 20, type: 0), SpaceInfo(id: 23, type: 4)])
        func plan(_ t: WindowMover.Target, _ ds: [DisplaySpaces] = [a, b]) -> WindowMover.Plan? {
            if case .success(let p) = WindowMover.plan(source: a, displays: ds, target: t) { return p } else { return nil }
        }
        expect(plan(.desktop(2)) == WindowMover.Plan(display: "A", to: 1, from: 0, crossDisplay: false), "Same display")
        expect(plan(.display("A", 2)) == plan(.desktop(2)), "Own display by uuid")
        expect(plan(.display("B", 3)) == WindowMover.Plan(display: "B", to: 2, from: 1, crossDisplay: true), "Other display, other desktop")
        expect(plan(.display("B", 0)) == WindowMover.Plan(display: "B", to: 1, from: 1, crossDisplay: true), "Other display, showing desktop")
        expect(plan(.nextDisplay) == plan(.display("B", 0)), "Next display")
        expect(plan(.display("B", 9)) == nil, "Missing desktop on other display")
        expect(plan(.display("C", 1)) == nil, "Unknown display")
        expect(plan(.nextDisplay, [a]) == nil, "No other display")
        if case .failure(let f) = WindowMover.plan(source: a, displays: [a, bFull], target: .nextDisplay) {
            expect(f == .targetFullScreen, "Full-screen other display")
        } else { preconditionFailure("Accepted full-screen drop target") }
        print("PASS: cross-display move plans")

        // --- auto-hidden Dock edge detection
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        expect(DockInspector.touchesEdge(CGPoint(x: 700, y: 899), screen: screen, orientation: .bottom), "Bottom edge")
        expect(!DockInspector.touchesEdge(CGPoint(x: 700, y: 880), screen: screen, orientation: .bottom), "Above bottom edge")
        expect(DockInspector.touchesEdge(CGPoint(x: 0, y: 400), screen: screen, orientation: .left), "Left edge")
        expect(!DockInspector.touchesEdge(CGPoint(x: 0, y: 400), screen: screen, orientation: .right), "Wrong edge")
        expect(!DockInspector.touchesEdge(CGPoint(x: 2000, y: 899), screen: screen, orientation: .bottom), "Other display")
        expect(DockInspector.revealDelay(delay: 0, animation: 0) == 0, "Instant Dock")
        expect(DockInspector.revealDelay(delay: .nan, animation: 100) == 3.0, "Bad Dock timing values are clamped")
        expect(DockInspector.isOnScreen(CGRect(x: -10, y: 854, width: 1460, height: 68), displays: [CGRect(x: 0, y: 0, width: 1440, height: 932)]), "Magnified Dock is on screen")
        expect(!DockInspector.isOnScreen(CGRect(x: 38, y: 932, width: 1364, height: 68), displays: [CGRect(x: 0, y: 0, width: 1440, height: 932)]), "Hidden Dock is off screen")
        expect(!DockInspector.isOnScreen(CGRect(x: 38, y: 900, width: 1364, height: 68), displays: [CGRect(x: 0, y: 0, width: 1440, height: 932)]), "Half-revealed Dock")
        print("PASS: auto-hidden Dock edge")

        // --- shortcuts
        let s1 = Shortcut(keyCode: 18, modifiers: Shortcut.ctrlOptCmd)
        expect(Shortcut(stored: s1.stored) == s1, "Shortcut round trip")
        expect(Shortcut(stored: "x") == nil && Shortcut(stored: "1:2:3") == nil && Shortcut(stored: "-1:0") == nil, "Bad stored shortcut")
        expect(s1.display.hasPrefix("⌃⌥⌘"), "Modifier order")
        expect(!Shortcut(keyCode: 0, modifiers: 512).isAcceptable && Shortcut(keyCode: 122, modifiers: 0).isAcceptable, "Shift-only rejected, F1 ok")
        let send1 = HotKeyAction.find("send.1")!, send2 = HotKeyAction.find("send.2")!
        expect(HotKeyBindings.shortcut(for: send1, stored: [:]) == send1.defaultShortcut, "Default binding")
        expect(HotKeyBindings.shortcut(for: send1, stored: ["send.1": ""]) == nil, "Disabled binding")
        expect(HotKeyBindings.duplicates(stored: [:]).isEmpty, "Defaults don't collide")
        expect(HotKeyBindings.duplicates(stored: ["send.1": send2.defaultShortcut!.stored]) == ["send.1", "send.2"], "Duplicate detection")
        let savedHotkeys = Prefs.hotkeys
        Prefs.hotkeys = [:]
        HotKeyBindings.set(send2.defaultShortcut, for: send1)
        expect(HotKeyBindings.shortcut(for: send1) == send2.defaultShortcut && HotKeyBindings.shortcut(for: send2) == nil, "Reassign steals")
        HotKeyBindings.set(send1.defaultShortcut, for: send1)
        expect(Prefs.hotkeys["send.1"] == nil, "Back to default is not stored")
        Prefs.hotkeys = savedHotkeys
        print("PASS: shortcut bindings")

        // --- updates
        expect(Updates.isNewer("1.1.0", than: "1.0.2") && Updates.isNewer("v1.10", than: "1.9.9"), "Newer versions")
        expect(!Updates.isNewer("1.1", than: "1.1.0") && !Updates.isNewer("1.0.2", than: "1.1"), "Not newer")
        expect(!Updates.isNewer("1.2.0-beta", than: "1.2.0"), "Suffix ignored")
        let release = Updates.parse(Data(#"{"tag_name":"v1.2.0","html_url":"https://github.com/x/y/releases/v1.2.0","body":"Notes","assets":[{"name":"SpaceKeeper-1.2.0.zip","browser_download_url":"https://e.x/a.zip"},{"name":"SpaceKeeper-1.2.0.dmg","browser_download_url":"https://e.x/a.dmg"}]}"#.utf8))
        expect(release?.version == "1.2.0" && release?.download?.absoluteString == "https://e.x/a.dmg", "Release parsing")
        expect(Updates.parse(Data(#"{"tag_name":"v2","html_url":"https://x","prerelease":true}"#.utf8)) == nil, "Skip prereleases")
        expect(Updates.parse(Data("nope".utf8)) == nil, "Garbage")
        print("PASS: update check")

        // --- layouts
        typealias E = SavedLayout.Entry
        let saved = [E(bundleID: "s", appName: "S", title: "Docs", display: "A", desktop: 2),
                     E(bundleID: "s", appName: "S", title: "Mail", display: "A", desktop: 1),
                     E(bundleID: "t", appName: "T", title: "", display: "Gone", desktop: 3),
                     E(bundleID: "u", appName: "U", title: "", display: "A", desktop: 7)]
        let now = [PlacedWindow(wid: 1, pid: 9, bundleID: "s", title: "Mail", display: "A", desktop: 2),
                   PlacedWindow(wid: 2, pid: 9, bundleID: "s", title: "Docs", display: "A", desktop: 1),
                   PlacedWindow(wid: 3, pid: 8, bundleID: "t", title: "x", display: "A", desktop: 1),
                   PlacedWindow(wid: 4, pid: 7, bundleID: "u", title: "", display: "A", desktop: 1),
                   PlacedWindow(wid: 5, pid: 6, bundleID: "v", title: "", display: "A", desktop: 1)]
        let moves = LayoutPlanner.plan(saved: saved, current: now, desktopCounts: ["A": 3])
        expect(moves.contains(LayoutMove(wid: 1, pid: 9, fromDisplay: "A", fromDesktop: 2, toDisplay: "A", toDesktop: 1)), "Title match")
        expect(moves.contains(LayoutMove(wid: 2, pid: 9, fromDisplay: "A", fromDesktop: 1, toDisplay: "A", toDesktop: 2)), "Title match 2")
        expect(moves.contains(LayoutMove(wid: 3, pid: 8, fromDisplay: "A", fromDesktop: 1, toDisplay: "A", toDesktop: 3)), "Missing display falls back")
        expect(!moves.contains { $0.wid == 4 || $0.wid == 5 }, "Missing desktop / unknown app untouched")
        expect(LayoutPlanner.plan(saved: saved, current: [], desktopCounts: ["A": 3]).isEmpty, "Nothing open")
        let inPlace = [PlacedWindow(wid: 1, pid: 9, bundleID: "s", title: "", display: "A", desktop: 1),
                       PlacedWindow(wid: 2, pid: 9, bundleID: "s", title: "", display: "A", desktop: 2)]
        expect(LayoutPlanner.plan(saved: Array(saved.prefix(2)).map { var e = $0; e.title = ""; return e },
                                  current: inPlace, desktopCounts: ["A": 3]).isEmpty, "Untitled windows already in place stay")
        print("PASS: layout restore plans")

        // --- desktop names
        expect(DesktopNames.key(display: "D", space: SpaceInfo(id: 1, type: 0)) == "D#main", "Original desktop key")
        expect(DesktopNames.key(display: "D", space: SpaceInfo(id: 3, type: 0, uuid: "U")) == "U", "Space uuid key")
        print("PASS: desktop name keys")
        print("All regression checks passed. No network requests or desktop input were generated.")
    }
}

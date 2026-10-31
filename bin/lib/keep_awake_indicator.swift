// KeepAwakeIndicator: the menu-bar half of bin/keep-awake.
//
// A tiny AppKit status item that shows Alex McRitchie whether the Mac is held
// awake, by whom, why and until when. It reads ONE file, the keep-awake
// state.json passed as its only argument, every few seconds, and quits itself
// when no hold is live or the supervisor that launched it is gone. It touches
// no keychain, no credential and no network: it reads a JSON file and draws.
//
// bin/lib/keep_awake.rb compiles it with swiftc on first use (cached by the
// source's digest) and the supervisor starts and stops it.

import AppKit
import Foundation

final class Indicator: NSObject, NSApplicationDelegate {
    let statePath: String
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?
    let isoParser = ISO8601DateFormatter()
    let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    init(statePath: String) {
        self.statePath = statePath
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = item.button {
            let image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Mac held awake")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    struct Holder {
        let by: String
        let reason: String
        let expires: Date
    }

    func readState() -> (holders: [Holder], supervisor: Int32?) {
        guard let data = FileManager.default.contents(atPath: statePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], nil)
        }
        let now = Date()
        let raw = json["holders"] as? [[String: Any]] ?? []
        let holders = raw.compactMap { h -> Holder? in
            guard let by = h["by"] as? String,
                  let expiresText = h["expires"] as? String,
                  let expires = isoParser.date(from: expiresText),
                  expires > now else { return nil }
            return Holder(by: by, reason: h["reason"] as? String ?? "", expires: expires)
        }
        let supervisor = (json["supervisor"] as? [String: Any])?["pid"] as? Int
        return (holders, supervisor.map { Int32($0) })
    }

    func refresh() {
        let state = readState()
        let supervisorAlive = state.supervisor.map { kill($0, 0) == 0 || errno == EPERM } ?? false
        if state.holders.isEmpty || !supervisorAlive {
            NSApp.terminate(nil)
            return
        }
        let latest = state.holders.map(\.expires).max()!
        item.button?.title = " \(clock.string(from: latest))"
        item.button?.toolTip = "Mac held awake until \(clock.string(from: latest))"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Mac held awake (caffeinate -dims)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        for h in state.holders.sorted(by: { $0.expires < $1.expires }) {
            let line = "\(h.by): until \(clock.string(from: h.expires))"
            menu.addItem(NSMenuItem(title: line, action: nil, keyEquivalent: ""))
            if !h.reason.isEmpty {
                let why = NSMenuItem(title: "    \(h.reason)", action: nil, keyEquivalent: "")
                menu.addItem(why)
            }
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Release with: keep-awake stop --by <holder>", action: nil, keyEquivalent: ""))
        let hide = NSMenuItem(title: "Hide indicator (the hold continues)", action: #selector(hideIndicator), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        item.menu = menu
    }

    @objc func hideIndicator() {
        NSApp.terminate(nil)
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: KeepAwakeIndicator <state.json>\n".data(using: .utf8)!)
    exit(2)
}
signal(SIGTERM) { _ in exit(0) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Indicator(statePath: arguments[1])
app.delegate = delegate
app.run()

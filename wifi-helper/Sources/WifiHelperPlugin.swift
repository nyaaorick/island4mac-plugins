import AppKit
import IslandKit
import Network

/// For public Wi-Fi that won't show its login page: finds the page the way macOS does (and a few more ways),
/// opens it in your browser, says what blocks it (a proxy's TUN mode, the system proxy, a stuck DNS) and fixes
/// what it can, and tells you the moment you're online
@main
struct WifiHelperPlugin: IslandPlugin {
    static let id = "wifi-helper"
    static let name = "Wi-Fi Helper"
    static let symbol = "wifi"
    static let version = "1.0.0"
    static let description: String? = "Finds a public Wi-Fi's login page when macOS won't, and clears what blocks it: TUN mode, proxies, DNS"
    /// Watches the network with its tab hidden, so a login is noticed as soon as the Wi-Fi asks for one
    static let background = true
    /// Turning the macOS login window off and reloading the DNS responder need root
    static let needsAdmin = true

    @Preference("Check the connection every", options: [(30, "30 seconds"), (60, "Minute"), (300, "5 minutes"), (0, "Only when the network changes")]) var seconds = 60
    @Preference("Popup when a login is needed") var warn = true
    @Preference("Open the login page by itself") var autoOpen = false
    @Preference("Beside the notch", options: [("problems", "Only when something's wrong"), ("always", "Always"), ("off", "Off")]) var compact = "problems"

    @State var network: NetworkSnapshot? = nil
    @State var report: ProbeReport? = nil
    @State var checking = false
    @State var lastCheck: Date? = nil
    @State var lastVerdict: String? = nil
    /// Set when the login page was opened: checks every 5 seconds until the Mac is online, for 3 minutes
    @State var watchingLogin: Date? = nil
    @State var message: String? = nil
    @State var messageFailed = false
    @State var messageAt: Date? = nil

    /// The network change watcher, kept for the plugin's life
    static var monitor: NWPathMonitor?
    /// When the network last changed, so a burst of changes is checked once, 2 seconds after the last
    static var changedAt: Date?

    var body: some IslandContent {
        if let besideNotch {
            besideNotch
        }
        if let message, let messageAt {
            Row(message, symbol: messageFailed ? "exclamationmark.triangle" : "checkmark.circle", state: messageFailed ? .failed : .done)
            Alarm(at: messageAt.addingTimeInterval(8), id: "message") { self.message = nil }
        }

        Section("Network", symbol: "wifi", detail: network?.interface)
        if let network {
            if network.isConnected {
                Row(network.ssid ?? network.service ?? "Connected",
                    subtitle: "IP \(network.ip ?? "?") · Gateway \(network.gateway ?? "?")" + (network.ssid == nil ? "\nNetwork name hidden by macOS" : ""),
                    symbol: "wifi", id: "network",
                    actions: [RowAction("Ping the gateway", symbol: "dot.radiowaves.left.and.right") { ping() }])
            } else {
                Row("Not connected", subtitle: "No interface has a route to the internet", symbol: "wifi.slash", state: .failed)
            }
            Row("DNS", subtitle: network.dns.isEmpty ? "No resolver" : network.dns.joined(separator: ", "), symbol: "server.rack", id: "dns",
                actions: dnsActions(network))
        } else {
            Row("Reading the network…", symbol: "wifi", state: .working)
        }

        Section("Internet", symbol: "globe", detail: lastCheck.map { "checked \($0.formatted(.relative(presentation: .named)))" })
        if let report {
            Row(verdictTitle(report), subtitle: verdictSubtitle(report), symbol: verdictSymbol(report),
                state: checking ? .working : verdictState(report), id: "verdict") { check() }
            if report.verdict == .captive, let portal = report.portal {
                Row("Open the login page", subtitle: portal, symbol: "safari", state: .attention, id: "login",
                    actions: [RowAction("Copy the link", symbol: "doc.on.doc") { copy(portal) }]) { openLogin(portal) }
            }
            for probe in report.probes {
                Row(probe.name, subtitle: probeSubtitle(probe), symbol: probeSymbol(probe), state: probeState(probe),
                    detail: probe.error == nil ? "\(probe.latency) ms" : nil, id: "probe-\(probe.id)")
            }
        } else {
            Row("Checking…", symbol: "globe", state: .working)
        }

        if let network {
            if network.fakeIP {
                Row("Clash TUN mode is on", subtitle: "It takes every request, DNS included, before the Wi-Fi has let you through, so the login redirect never arrives. Turn TUN off in Clash, log in, then turn it back on.",
                    symbol: "network.badge.shield.half.filled", state: .attention)
            } else if !network.tunnels.isEmpty {
                Row("A tunnel is on: \(network.tunnels.joined(separator: ", "))",
                    subtitle: "A VPN or a proxy's TUN mode can hold the login page back. Turn it off if the page won't load, and on again once you're online.",
                    symbol: "lock.shield")
            }
            if network.systemProxy {
                Row("The system proxy is on", subtitle: "Browser requests go to the local proxy first; while it has no internet, the login page fails with a 502. Turn it off, log in, then turn it back on in your proxy app.",
                    symbol: "arrow.triangle.branch", state: .attention, id: "proxy",
                    actions: [RowAction("Turn it off", symbol: "xmark.circle", confirm: "Turn the system proxy off on \(network.service ?? "this network")?") { disableProxy() }])
            }
            if !network.proxyApps.isEmpty, !network.fakeIP {
                Row("Proxy app running: \(network.proxyApps.prefix(3).joined(separator: ", "))",
                    subtitle: "Fine as long as its TUN mode is off while you log in", symbol: "network")
            }
            Toggle("macOS login window", subtitle: network.loginWindowOff
                   ? "Off: macOS won't pop up its own captive portal window. Log in from the page above instead"
                   : "macOS pops up its own login window, which crashes on some portals and blocks pasting. Turn it off to log in from your browser",
                   symbol: "macwindow", isOn: !network.loginWindowOff, id: "login-window") { on in setLoginWindow(on) }
        }

        if !checking {
            Button("Check again", symbol: "arrow.clockwise") { check() }
        }
        if let portal = report?.portal, report?.verdict == .captive {
            Button("Open the login page", symbol: "safari") { openLogin(portal) }
        }
    }

    // MARK: - Words

    func verdictTitle(_ report: ProbeReport) -> String {
        switch report.verdict {
        case .online: "Online"
        case .captive: "This network wants a login"
        case .offline: network?.isConnected == true ? "No internet" : "Not connected"
        case .partial: "Flaky connection"
        }
    }

    func verdictSubtitle(_ report: ProbeReport) -> String {
        let passed = report.probes.filter(\.succeeded).count
        switch report.verdict {
        case .online: return "\(passed) of \(report.probes.count) checks passed"
        case .captive: return "Found by \(report.foundBy ?? "a check"). Open the page, log in, and you'll hear when you're through"
        case .offline: return report.probes.isEmpty ? "Join a network first" : "Every check failed. Some portals drop traffic until you log in: try the gateway's page, or turn a VPN or TUN mode off"
        case .partial: return "Only \(passed) of \(report.probes.count) checks passed"
        }
    }

    func verdictSymbol(_ report: ProbeReport) -> String {
        switch report.verdict {
        case .online: "checkmark.circle"
        case .captive: "person.badge.key"
        case .offline: "wifi.slash"
        case .partial: "wifi.exclamationmark"
        }
    }

    func verdictState(_ report: ProbeReport) -> ItemState {
        switch report.verdict {
        case .online: .done
        case .captive: .attention
        case .offline: .failed
        case .partial: .attention
        }
    }

    func probeSubtitle(_ probe: ProbeResult) -> String {
        if let error = probe.error { return error }
        if probe.captive { return "Intercepted: \(probe.portal ?? "a page in place of the answer")" }
        return "OK, HTTP \(probe.status)"
    }

    func probeSymbol(_ probe: ProbeResult) -> String {
        switch probe.id {
        case "apple": "apple.logo"
        case "gateway": "wifi.router"
        case "dhcp": "doc.badge.gearshape"
        default: "globe"
        }
    }

    func probeState(_ probe: ProbeResult) -> ItemState {
        if probe.error != nil { return .failed }
        return probe.captive ? .attention : .done
    }

    var besideNotch: Compact? {
        guard compact != "off" else { return nil }
        switch report?.verdict {
        case .captive: return Compact(symbol: "wifi.exclamationmark", text: "Login", state: .attention)
        case .offline: return Compact(symbol: "wifi.slash", text: "Offline", state: .failed)
        case .partial: return Compact(symbol: "wifi.exclamationmark", text: "Flaky")
        case .online: return compact == "always" ? Compact(symbol: "wifi", text: network?.ssid ?? "Online") : nil
        case nil: return nil
        }
    }

    func dnsActions(_ network: NetworkSnapshot) -> [RowAction] {
        var actions = [RowAction("Flush the cache", symbol: "arrow.triangle.2.circlepath") { flushDNS() }]
        if let service = network.service {
            actions.append(RowAction("Back to automatic", symbol: "arrow.uturn.backward",
                                     confirm: "Set DNS on \(service) back to what the router hands out?") { resetDNS(service) })
        }
        return actions
    }

    // MARK: - Watching

    func onStart() {
        check()
        let monitor = NWPathMonitor()
        // The first update describes the network as it is, which the check above already reads
        nonisolated(unsafe) var first = true
        monitor.pathUpdateHandler = { _ in
            if first { first = false; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { Self.changedAt = Date() } }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        Self.monitor = monitor

        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = Date()
                if let changed = Self.changedAt, now.timeIntervalSince(changed) >= 2 {
                    Self.changedAt = nil
                    check()
                    return
                }
                if let since = watchingLogin {
                    if now.timeIntervalSince(since) > 180 { watchingLogin = nil }
                    else if let lastCheck, now.timeIntervalSince(lastCheck) >= 5 { check() }
                    return
                }
                if seconds > 0, let lastCheck, now.timeIntervalSince(lastCheck) >= Double(seconds) {
                    check()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func check() {
        guard !checking else { return }
        checking = true
        Task {
            let snapshot = await NetworkReader.read()
            network = snapshot
            let report = snapshot.isConnected
                ? await PortalProber.probe(gateway: snapshot.gateway, dhcpPortal: snapshot.dhcpPortal)
                : ProbeReport(verdict: .offline, at: Date())
            self.report = report
            checking = false
            lastCheck = Island.now
            react(to: report)
        }
    }

    /// Says so when a login turns up, and when it worked
    func react(to report: ProbeReport) {
        defer { lastVerdict = report.verdict.rawValue }
        if report.verdict == .captive, lastVerdict != ProbeReport.Verdict.captive.rawValue {
            if warn {
                Island.popup("This Wi-Fi wants a login", symbol: "wifi.exclamationmark", seconds: 5)
                Island.open()
            }
            if autoOpen, let portal = report.portal { openLogin(portal) }
        }
        if watchingLogin != nil, report.verdict == .online {
            watchingLogin = nil
            Island.popup("You're online", symbol: "checkmark.circle", seconds: 4)
            show("Logged in: you're online")
        }
    }

    // MARK: - Doing

    func openLogin(_ portal: String) {
        guard let url = URL(string: portal) else { return show("Not a link: \(portal)", failed: true) }
        NSWorkspace.shared.open(url)
        watchingLogin = Island.now
        show("Opened in your browser. You'll hear when you're online")
    }

    func ping() {
        guard let gateway = network?.gateway else { return }
        Task {
            let result = await Shell.run("ping", ["-c", "1", "-W", "1500", gateway])
            if let time = result.output.firstMatch(of: /time=([\d.]+) ms/) {
                show("Gateway \(gateway) answered in \(time.output.1) ms")
            } else {
                show("Gateway \(gateway) didn't answer", failed: true)
            }
        }
    }

    func flushDNS() {
        Task {
            _ = await Shell.run("dscacheutil", ["-flushcache"])
            let reload = await Island.sudo("/usr/bin/killall", ["-HUP", "mDNSResponder"])
            if reload.succeeded {
                show("DNS cache flushed and the resolver reloaded")
            } else {
                show("DNS cache flushed. To reload the resolver too, allow Wi-Fi Helper administrator access under Settings > Plugins")
            }
            check()
        }
    }

    func resetDNS(_ service: String) {
        Task {
            let result = await asAdministratorIfNeeded("/usr/sbin/networksetup", ["-setdnsservers", service, "Empty"])
            show(result.succeeded ? "DNS on \(service) is automatic again" : "Couldn't change DNS: \(reason(result))", failed: !result.succeeded)
            check()
        }
    }

    func disableProxy() {
        guard let service = network?.service else { return show("Couldn't tell which network service to change", failed: true) }
        Task {
            var failed: ShellResult?
            for kind in ["-setwebproxystate", "-setsecurewebproxystate", "-setsocksfirewallproxystate"] {
                let result = await asAdministratorIfNeeded("/usr/sbin/networksetup", [kind, service, "off"])
                if !result.succeeded { failed = result }
            }
            if let failed {
                show("Couldn't turn the proxy off: \(reason(failed))", failed: true)
            } else {
                show("System proxy off on \(service). Turn it back on in your proxy app once you're online")
            }
            check()
        }
    }

    /// The Captive Network Assistant: `Active = false` in com.apple.captive.control keeps macOS from popping up
    /// its own window; deleting the key restores it
    func setLoginWindow(_ on: Bool) {
        Task {
            let plist = "/Library/Preferences/SystemConfiguration/com.apple.captive.control"
            let result = on
                ? await Island.sudo("/usr/bin/defaults", ["delete", plist, "Active"])
                : await Island.sudo("/usr/bin/defaults", ["write", plist, "Active", "-bool", "false"])
            if result.succeeded {
                show(on ? "macOS shows its own login window again" : "macOS login window off: log in from your browser")
            } else {
                show("Couldn't change it: \(reason(result))", failed: true)
            }
            network = await NetworkReader.read()
        }
    }

    /// As the user first; through the island as an administrator if macOS refused
    func asAdministratorIfNeeded(_ program: String, _ arguments: [String]) async -> ShellResult {
        let own = await Shell.run(program, arguments)
        if own.succeeded { return own }
        return await Island.sudo(program, arguments)
    }

    func reason(_ result: ShellResult) -> String {
        let text = (result.error.isEmpty ? result.output : result.error).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "status \(result.status)" : text
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show("Link copied")
    }

    func show(_ text: String, failed: Bool = false) {
        message = text
        messageFailed = failed
        messageAt = Island.now
    }
}

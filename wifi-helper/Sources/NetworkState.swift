import CoreWLAN
import Foundation
import IslandKit

/// What the Mac's network looks like right now, read from the system's own tools
struct NetworkSnapshot: Codable, Equatable, Sendable {
    /// The interface with the default route (en0)
    var interface: String? = nil
    /// Its network service, the name networksetup wants ("Wi-Fi")
    var service: String? = nil
    var ip: String? = nil
    var gateway: String? = nil
    /// nil when macOS hides it (it needs Location access, which a plugin doesn't have)
    var ssid: String? = nil
    var dns: [String] = []
    /// The captive portal address the DHCP server advertised (RFC 8910, option 114)
    var dhcpPortal: String? = nil
    /// Tunnel interfaces with an IPv4 address: a VPN, or a proxy's TUN mode ("utun3 10.0.0.2")
    var tunnels: [String] = []
    /// A tunnel in Clash's fake-IP range (198.18.0.0/15): TUN mode is on and takes every request
    var fakeIP = false
    var proxyApps: [String] = []
    /// HTTP, HTTPS or SOCKS proxy turned on in System Settings
    var systemProxy = false
    /// The built-in Captive Network Assistant window is turned off
    var loginWindowOff = false

    var isConnected: Bool { ip != nil && gateway != nil }
}

/// Reads a NetworkSnapshot with route, ipconfig, scutil, ifconfig, pgrep and networksetup, in parallel
@MainActor
enum NetworkReader {
    static func read() async -> NetworkSnapshot {
        var snapshot = NetworkSnapshot()
        let route = await Shell.run("route", ["-n", "get", "default"])
        for line in route.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") { snapshot.interface = value(of: trimmed) }
            if trimmed.hasPrefix("gateway:") { snapshot.gateway = value(of: trimmed) }
        }

        async let ifconfig = Shell.run("ifconfig")
        async let processes = Shell.run("pgrep", ["-il", "clash|mihomo|sing-box|surge"])
        async let proxy = Shell.run("scutil", ["--proxy"])
        async let loginWindow = Shell.run("defaults", ["read", "/Library/Preferences/SystemConfiguration/com.apple.captive.control", "Active"])
        async let services = Shell.run("networksetup", ["-listnetworkserviceorder"])
        async let dns = Shell.run("scutil", ["--dns"])

        if let interface = snapshot.interface {
            async let ip = Shell.run("ipconfig", ["getifaddr", interface])
            async let airport = Shell.run("networksetup", ["-getairportnetwork", interface])
            async let packet = Shell.run("ipconfig", ["getpacket", interface])
            let address = await ip.output.trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot.ip = address.isEmpty ? nil : address
            snapshot.ssid = ssid(from: await airport.output, interface: interface)
            snapshot.dhcpPortal = dhcpField(["captive_portal", "114", "unknown_114"], in: await packet.output)
            snapshot.service = service(for: interface, in: await services.output)
        }

        snapshot.dns = nameservers(in: await dns.output)
        (snapshot.tunnels, snapshot.fakeIP) = tunnels(in: await ifconfig.output)
        snapshot.proxyApps = await processes.lines.compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            return parts.count == 2 ? String(parts[1]) : nil
        }
        let proxyOutput = await proxy.output
        snapshot.systemProxy = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable"].contains { proxyOutput.contains("\($0) : 1") }
        snapshot.loginWindowOff = await loginWindow.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
        return snapshot
    }

    private static func value(of line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// networksetup prints it when macOS lets it; CoreWLAN answers only with Location access. Either may be nil
    private static func ssid(from airport: String, interface: String) -> String? {
        if let range = airport.range(of: "Current Wi-Fi Network:") {
            let name = airport[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !name.contains("<redacted>") { return name }
        }
        if let name = CWWiFiClient.shared().interface(withName: interface)?.ssid(), !name.isEmpty { return name }
        return nil
    }

    /// "captive_portal (uri): http://…" in ipconfig getpacket's output
    private static func dhcpField(_ names: [String], in packet: String) -> String? {
        for line in packet.split(separator: "\n") {
            for name in names where line.hasPrefix("\(name) (") {
                if let colon = line.firstIndex(of: ":") {
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { return value }
                }
            }
        }
        return nil
    }

    /// The service whose "(Hardware Port: Wi-Fi, Device: en0)" line names the interface: its name is on the line before
    private static func service(for interface: String, in order: String) -> String? {
        var name: String?
        for line in order.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("("), let close = trimmed.firstIndex(of: ")"), !trimmed.contains("Hardware Port") {
                name = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
            } else if trimmed.contains("Device: \(interface))") {
                return name
            }
        }
        return nil
    }

    /// Every resolver scutil lists, once each, without link-local ones
    private static func nameservers(in output: String) -> [String] {
        var servers: [String] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("nameserver["), let colon = trimmed.firstIndex(of: ":") else { continue }
            let server = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !server.isEmpty, !server.hasPrefix("fe80"), server != "::1", !servers.contains(server) { servers.append(server) }
        }
        return servers
    }

    /// utun interfaces that carry an IPv4 address and are up, and whether one sits in Clash's fake-IP range
    private static func tunnels(in ifconfig: String) -> ([String], Bool) {
        var tunnels: [String] = []
        var fakeIP = false
        var name = "", running = false, address: String?
        func finish() {
            guard name.hasPrefix("utun") || name.hasPrefix("tun"), running, let address else { return }
            tunnels.append("\(name) \(address)")
            if address.hasPrefix("198.18.") || address.hasPrefix("198.19.") { fakeIP = true }
        }
        for line in ifconfig.split(separator: "\n") {
            if !line.hasPrefix("\t"), !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") {
                finish()
                name = String(line[..<colon])
                running = line.contains("RUNNING") && line.contains("POINTOPOINT")
                address = nil
            } else if address == nil {
                let parts = line.split(separator: " ")
                if let inet = parts.firstIndex(of: "inet"), inet + 1 < parts.count { address = String(parts[inet + 1]) }
            }
        }
        finish()
        return (tunnels, fakeIP)
    }
}

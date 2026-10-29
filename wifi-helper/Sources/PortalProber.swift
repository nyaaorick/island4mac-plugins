import Foundation

/// What one connectivity check came to
struct ProbeResult: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var status = 0
    /// Milliseconds
    var latency = 0
    /// The network got in the way of the request: a redirect or a page in place of the expected answer
    var captive = false
    /// Where it sent us, or the page it served: the login page, most likely
    var portal: String? = nil
    var error: String? = nil
    /// What was asked
    var url: String? = nil

    var succeeded: Bool { error == nil && !captive }
}

struct ProbeReport: Codable, Equatable, Sendable {
    enum Verdict: String, Codable, Sendable {
        case online, captive, offline, partial
    }

    var verdict: Verdict
    /// The login page, when the verdict is captive
    var portal: String? = nil
    /// Which check found it
    var foundBy: String? = nil
    var probes: [ProbeResult] = []
    var at: Date
}

/// Asks the connectivity checks Apple, Google, Microsoft and Cloudflare run, the DHCP-advertised portal and the
/// gateway itself, all at once and without following redirects, to tell whether the Wi-Fi wants a login and where
enum PortalProber {
    struct Check: Sendable {
        let id: String
        let name: String
        let url: String
        let statuses: [Int]
        let bodyMarker: String?
    }

    static let checks = [
        Check(id: "apple", name: "Apple", url: "http://captive.apple.com/hotspot-detect.html", statuses: [200], bodyMarker: "Success"),
        Check(id: "google", name: "Google", url: "http://connectivitycheck.gstatic.com/generate_204", statuses: [204], bodyMarker: nil),
        Check(id: "microsoft", name: "Microsoft", url: "http://www.msftconnecttest.com/connecttest.txt", statuses: [200], bodyMarker: "Microsoft Connect Test"),
        Check(id: "cloudflare", name: "Cloudflare", url: "http://cp.cloudflare.com/", statuses: [200, 204], bodyMarker: nil),
    ]

    /// Ports real portal controllers answer on (hotel and airport systems, Cisco ISE, Aruba, Mikrotik, OpenNDS)
    static let gatewayPorts = [80, 8080, 8003, 8880]

    static func probe(gateway: String?, dhcpPortal: String?) async -> ProbeReport {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        var results = await withTaskGroup(of: ProbeResult?.self, returning: [ProbeResult].self) { group in
            for check in checks {
                group.addTask { await run(check, session: session) }
            }
            if let dhcpPortal {
                group.addTask { await probeDHCP(dhcpPortal, session: session) }
            }
            if let gateway {
                group.addTask { await probeGateway(gateway, session: session) }
            }
            var results: [ProbeResult] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }
        let order = checks.map(\.id) + ["dhcp", "gateway"]
        results.sort { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }

        let wellKnown = results.filter { checks.map(\.id).contains($0.id) }
        let passed = wellKnown.filter(\.succeeded).count
        let dhcp = results.first { $0.id == "dhcp" && $0.captive && $0.portal != nil }
        let redirected = wellKnown.first { $0.captive && $0.portal != nil }
        let gatewayPage = results.first { $0.id == "gateway" && $0.captive && $0.portal != nil }

        var report = ProbeReport(verdict: .partial, probes: results, at: Date())
        if let hit = dhcp ?? redirected {
            // The network's own answer first, then a redirect one of the checks ran into
            report.verdict = .captive
            report.portal = hit.portal
            report.foundBy = hit.name
        } else if passed >= 2 {
            report.verdict = .online
        } else if passed == 0, let gatewayPage {
            // Every check was dropped rather than redirected, and the gateway serves a page: that is the portal
            report.verdict = .captive
            report.portal = gatewayPage.portal
            report.foundBy = gatewayPage.name
        } else if wellKnown.allSatisfy({ $0.error != nil }) {
            report.verdict = .offline
        }
        return report
    }

    // MARK: - One check

    private static func run(_ check: Check, session: URLSession) async -> ProbeResult {
        var result = ProbeResult(id: check.id, name: check.name, url: check.url)
        let started = Date()
        do {
            let (body, response) = try await fetch(check.url, session: session, userAgent: "CaptiveNetworkSupport-425.0.1/1.0")
            result.latency = milliseconds(since: started)
            result.status = response.statusCode
            if let location = redirect(of: response, from: check.url) {
                result.captive = true
                result.portal = location
            } else if check.statuses.contains(response.statusCode), check.bodyMarker.map({ body.contains($0) }) ?? true {
                result.captive = false
            } else {
                // The right status with the wrong page, or a page in place of a 204: something answered in its stead
                result.captive = true
                result.portal = htmlRedirect(in: body, from: check.url) ?? check.url
            }
        } catch {
            result.latency = milliseconds(since: started)
            result.error = describe(error)
        }
        return result
    }

    /// RFC 8910: the DHCP server named the portal API itself, host and port included. It answers with JSON
    /// (captive and user-portal-url), a redirect or the page
    private static func probeDHCP(_ address: String, session: URLSession) async -> ProbeResult {
        var result = ProbeResult(id: "dhcp", name: "DHCP portal (RFC 8910)", url: address)
        let started = Date()
        do {
            let (body, response) = try await fetch(address, session: session, userAgent: "CaptiveNetworkSupport-425.0.1/1.0",
                                                   accept: "application/captive+json, text/html, */*")
            result.latency = milliseconds(since: started)
            result.status = response.statusCode
            if let location = redirect(of: response, from: address) {
                result.captive = true
                result.portal = location
            } else if (response.value(forHTTPHeaderField: "Content-Type") ?? "").contains("application/captive+json"),
                      let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] {
                if json["captive"] as? Bool == true {
                    result.captive = true
                    result.portal = json["user-portal-url"] as? String ?? address
                }
            } else if let page = htmlRedirect(in: body, from: address) ?? (response.statusCode != 204 && !body.isEmpty ? address : nil) {
                result.captive = true
                result.portal = page
            }
        } catch {
            result.latency = milliseconds(since: started)
            result.error = describe(error)
        }
        return result
    }

    /// The gateway on each port at once; the one that redirects wins, else the first that answers
    private static func probeGateway(_ gateway: String, session: URLSession) async -> ProbeResult {
        let results = await withTaskGroup(of: ProbeResult.self, returning: [ProbeResult].self) { group in
            for port in gatewayPorts {
                group.addTask { await probeGateway(gateway, port: port, session: session) }
            }
            var results: [ProbeResult] = []
            for await result in group { results.append(result) }
            return results
        }
        // A port that sends us somewhere else names the login page; one that only serves a page may be the portal
        let redirecting = results.first { $0.captive && $0.portal != nil && $0.portal != $0.url }
        let answered = results.first { $0.error == nil }
        var result = redirecting ?? answered ?? results[0]
        result.id = "gateway"
        return result
    }

    private static func probeGateway(_ gateway: String, port: Int, session: URLSession) async -> ProbeResult {
        let address = "http://\(gateway):\(port)/"
        var result = ProbeResult(id: "gateway:\(port)", name: "Gateway \(gateway):\(port)", url: address)
        let started = Date()
        do {
            let (body, response) = try await fetch(address, session: session, userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")
            result.latency = milliseconds(since: started)
            result.status = response.statusCode
            // A gateway that serves a page at / may well be serving the portal itself
            if let page = redirect(of: response, from: address) ?? htmlRedirect(in: body, from: address) ?? (response.statusCode != 204 ? address : nil) {
                result.captive = true
                result.portal = page
            }
        } catch {
            result.latency = milliseconds(since: started)
            result.error = describe(error)
        }
        return result
    }

    // MARK: - HTTP

    /// Never follows a redirect: the 3xx is the answer we're after
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3.5
        configuration.timeoutIntervalForResource = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }

    private static func fetch(_ address: String, session: URLSession, userAgent: String, accept: String? = nil) async throws -> (String, HTTPURLResponse) {
        guard let url = URL(string: address) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (String(decoding: data.prefix(64_000), as: UTF8.self), http)
    }

    private static func redirect(of response: HTTPURLResponse, from address: String) -> String? {
        guard (300..<400).contains(response.statusCode), let location = response.value(forHTTPHeaderField: "Location") else { return nil }
        return URL(string: location, relativeTo: URL(string: address))?.absoluteString ?? location
    }

    /// A meta refresh, a script that sets location, or a form's action: where a 200 page sends you
    static func htmlRedirect(in html: String, from address: String) -> String? {
        let patterns = [
            /<meta[^>]*http-equiv=["']?refresh["']?[^>]*url=([^"'>\s]+)/.ignoresCase(),
            /location(?:\.href|\.replace)?\s*(?:=|\()\s*["']([^"']+)["']/.ignoresCase(),
            /<form[^>]*action=["']([^"']+)["']/.ignoresCase(),
        ]
        for pattern in patterns {
            guard let match = html.firstMatch(of: pattern) else { continue }
            let target = String(match.output.1)
            guard target.hasPrefix("http") || target.hasPrefix("/") else { continue }
            return URL(string: target, relativeTo: URL(string: address))?.absoluteString ?? target
        }
        return nil
    }

    private static func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private static func describe(_ error: Error) -> String {
        switch (error as? URLError)?.code {
        case .timedOut: "Timed out"
        case .cannotFindHost, .dnsLookupFailed: "Name not found"
        case .cannotConnectToHost: "Refused"
        case .notConnectedToInternet: "Not connected"
        case .networkConnectionLost: "Connection lost"
        default: error.localizedDescription
        }
    }
}

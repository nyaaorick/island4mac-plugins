import Foundation
import IslandKit

/// Whether GitHub is up: an example of @Fetched. It runs only to refresh, every 5 minutes
@main
struct GitHubStatus: IslandPlugin {
    static let id = "github-status"
    static let name = "GitHub Status"
    static let symbol = "server.rack"
    static let version = "1.0.0"
    static let description: String? = "Whether GitHub is up, refreshed every 5 minutes"
    static let lifecycle = Lifecycle.onDemand

    struct Summary: Decodable {
        struct Status: Decodable { let indicator: String; let description: String }
        let status: Status
    }

    @Fetched(Summary.self, from: "https://www.githubstatus.com/api/v2/status.json", every: .minutes(5)) var summary

    var body: some IslandContent {
        if let status = summary?.status {
            Row(status.description, subtitle: $summary.updated.map { "Checked \($0.formatted(date: .omitted, time: .shortened))" },
                symbol: status.indicator == "none" ? "checkmark.circle" : "exclamationmark.triangle")
            if status.indicator != "none" {
                Compact(symbol: "exclamationmark.triangle", text: "GitHub")
            }
        }
        Button("Refresh", symbol: "arrow.clockwise") { $summary.refresh() }
    }
}

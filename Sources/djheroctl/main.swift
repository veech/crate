import DJHeroCore
import Foundation

let arguments = CommandLine.arguments
let cfg = Config()
let store = try Store(at: cfg.dbURL)

switch arguments.count > 1 ? arguments[1] : "help" {
case "auth":
    for row in await AuthStatus.check(cfg: cfg, store: store) {
        print("\(row.service.padding(toLength: 11, withPad: " ", startingAt: 0)) "
            + "\(row.state.padding(toLength: 8, withPad: " ", startingAt: 0)) \(row.detail)")
    }

case "cycle":
    try await Reconciler(cfg: cfg, store: store).cycle()
    let counts = try store.statusCounts()
    print(counts.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        .isEmpty ? "no tracks" : counts.sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }.joined(separator: " "))

case "ytm-search":
    let query = arguments.dropFirst(2).joined(separator: " ")
    for c in try await YTMusicClient().searchSongs(query).prefix(8) {
        print("\(c.videoId)  \(c.durationS)s  \(c.title) — \(c.artists)")
    }

case "settings":
    let s = try store.loadSettings()
    print(s)

default:
    print("usage: djheroctl auth | cycle | ytm-search <query> | settings")
}

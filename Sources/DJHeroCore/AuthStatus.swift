import Foundation

public struct AuthRow: Sendable {
    public let service: String
    public let state: String  // missing | invalid | ok
    public let detail: String
}

/// Credential health; checks run concurrently, caller waits for the slowest.
public enum AuthStatus {
    public static func check(cfg: Config, store: Store) async -> [AuthRow] {
        let model = (try? store.loadSettings())?.anthropicModel ?? "claude-opus-5"
        async let sc = checkSoundCloud(cfg)
        async let yt = checkYouTube(cfg)
        async let bp = checkBeatport(cfg)
        async let ai = checkAnthropic(model)
        return await [sc, yt, bp, ai]
    }

    static func checkSoundCloud(_ cfg: Config) async -> AuthRow {
        let file = cfg.cookies("soundcloud")
        guard FileManager.default.fileExists(atPath: file.path) else {
            return AuthRow(service: "soundcloud", state: "missing", detail: "No cookies saved yet")
        }
        do {
            let client = try SoundCloudClient(cookiesFile: file, cacheDir: cfg.cacheDir)
            let me = try await client.me()
            let plan = JSON.string(
                JSON.dict(JSON.dict(me["consumer_subscription"])["product"])["id"]) ?? "free"
            var detail = "Logged in as \(JSON.string(me["username"]) ?? "?") (\(plan))"
            if plan == "free" { detail += " — no Go+, rips fall below the 256k floor" }
            return AuthRow(service: "soundcloud", state: plan == "free" ? "invalid" : "ok",
                           detail: detail)
        } catch {
            return AuthRow(service: "soundcloud", state: "invalid", detail: "\(error)")
        }
    }

    static func checkYouTube(_ cfg: Config) async -> AuthRow {
        let file = cfg.cookies("youtube")
        guard FileManager.default.fileExists(atPath: file.path) else {
            return AuthRow(service: "youtube", state: "missing", detail: "No cookies saved yet")
        }
        do {
            if try await YtDlp.probePremium(cookies: file) {
                return AuthRow(service: "youtube", state: "ok",
                               detail: "Premium formats (256k AAC) available")
            }
            return AuthRow(service: "youtube", state: "invalid",
                           detail: "Cookies load but 256k formats unavailable — no Premium, or expired")
        } catch {
            return AuthRow(service: "youtube", state: "invalid", detail: "\(error)")
        }
    }

    static func checkBeatport(_ cfg: Config) async -> AuthRow {
        let file = cfg.cookies("beatport")
        guard FileManager.default.fileExists(atPath: file.path) else {
            return AuthRow(service: "beatport", state: "missing", detail: "No cookies saved yet")
        }
        do {
            let client = try await BeatportClient(cookiesFile: file)
            let account = try await client.myAccount()
            let who = JSON.string(account["username"]) ?? JSON.string(account["email"]) ?? "?"
            return AuthRow(service: "beatport", state: "ok", detail: "Logged in as \(who)")
        } catch {
            return AuthRow(service: "beatport", state: "invalid", detail: "\(error)")
        }
    }

    static func checkAnthropic(_ model: String) async -> AuthRow {
        guard ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] != nil else {
            return AuthRow(service: "anthropic", state: "missing",
                           detail: "Set ANTHROPIC_API_KEY — messy titles fall back to heuristics, "
                               + "ambiguous matches go to review")
        }
        do {
            try await Anthropic.countTokens(model: model)
            return AuthRow(service: "anthropic", state: "ok", detail: "Key valid (\(model))")
        } catch {
            return AuthRow(service: "anthropic", state: "invalid", detail: "\(error)")
        }
    }
}

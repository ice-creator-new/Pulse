import Foundation

/// Xiaomi's MiMo open platform, read through the console's own endpoints.
///
/// **A browser session, not a key.** The platform issues API keys for
/// inference, and none of them answer the console's account routes — the plan
/// and the balance are behind the same `api-platform_serviceToken` cookie the
/// web console uses. So the credential is a session, as Ollama's is, with the
/// same consequences: Safari's store needs Full Disk Access, and Chromium's
/// asks for keychain permission once.
///
/// **Two products on one account, two rings.** The account carries a monthly
/// token allowance bought as a plan and a prepaid cash balance for anything
/// past it. They are separate `Provider` rows — `xiaomiMiMo` is the plan,
/// `xiaomiAPI` is the purse — because a single ring can only show one figure
/// and both will bite. This file holds the shared client and both services;
/// see `XiaomiAPIUsageService` for the money half.
enum XiaomiMiMoError: Error, Equatable {
    case missingCookie
    case invalidCookie
    /// The session is there and the platform refused it — expired, or signed
    /// out elsewhere. Separate from `missingCookie`, because one is "set this
    /// up" and the other is "you already did, do it again".
    case sessionExpired
    case noPlan
    case unreadableReply(String)
    case rateLimited
    case serverError
    /// Nothing came back at all — no network, DNS, TLS, a timeout. Distinct
    /// from `unreadableReply`, which means something did come back.
    case unreachable
}

/// What one read of the console returns.
struct XiaomiMiMoSnapshot: Equatable, Sendable {
    /// The plan's month of tokens: used, and out of how many. Nil on an
    /// account that has no plan running, which is a real state rather than a
    /// failed read.
    struct Plan: Equatable, Sendable {
        let used: Int
        let limit: Int
        let periodEnd: Date?
        /// The plan's name as Settings shows it: the detail route's
        /// `planName` when it has one, `planCode` as the fallback. A live
        /// reply carries both fields side by side — a *name* field is the
        /// platform's own claim about which is which, and every other
        /// provider in Pulse shows a name rather than an identifier.
        let name: String?
    }

    let plan: Plan?
    /// Money left on the account, and in what. Reported by every account,
    /// including one with no plan.
    let balance: Double?
    let currency: String?
}

/// The cookie names the console's own requests carry.
///
/// Only these are kept. A browser store for this host also holds analytics and
/// preference cookies, and a credential store that forwards everything it
/// found is a credential store that leaks whatever the site adds next.
enum XiaomiMiMoCookie {
    /// The two the platform will not answer without.
    static let required = ["api-platform_serviceToken", "userId"]
    /// Sent when present. The console includes them and the endpoints work
    /// without them, so they are carried rather than required — a session that
    /// only has the two above is still a session.
    static let optional = ["api-platform_ph", "api-platform_slh"]

    /// A `Cookie:` header reduced to the names above, or nil if the two
    /// required ones are not both in it.
    ///
    /// Takes what a browser store hands over *or* what somebody pasted out of
    /// their network tab, which is why the `Cookie:` prefix is tolerated and
    /// why the value is checked rather than trusted: a header assembled from
    /// an arbitrary string is a header injection if a value carries a newline.
    static func normalize(_ input: String) throws -> String {
        guard !input.unicodeScalars.contains(where: { $0.value < 32 || $0.value > 126 }) else {
            throw XiaomiMiMoError.invalidCookie
        }
        var header = input.trimmingCharacters(in: .whitespaces)
        if header.lowercased().hasPrefix("cookie:") {
            header = String(header.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        guard !header.isEmpty else { throw XiaomiMiMoError.missingCookie }
        guard header.utf8.count <= 32_768 else { throw XiaomiMiMoError.invalidCookie }

        let wanted = Set(required + optional)
        var kept: [String] = []
        var seen = Set<String>()
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            guard wanted.contains(name) else { continue }
            // Chrome quotes this platform's serviceToken on the wire, so the
            // header pasted out of a network tab arrives with a matched pair
            // around the value — RFC 6265's own spelling of a quoted
            // cookie-value. Stripped, not refused: the documented paste path
            // would otherwise reject the platform's own session, and the API
            // accepts the bare value back (checked against the live route).
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value.removeFirst()
                value.removeLast()
                value = value.trimmingCharacters(in: .whitespaces)
            }
            // A quote that is not wrapping the whole value, a backslash or a
            // space is still a refusal: structure this parser does not model,
            // in a header assembled from an arbitrary string.
            guard !value.isEmpty, !value.contains("\""), !value.contains("\\"),
                  !value.contains(" ") else {
                throw XiaomiMiMoError.invalidCookie
            }
            // A host-only row and a domain row for one name is normal in every
            // browser store, and the host match returns both. The first wins,
            // as it does in any cookie header — throwing here would discard
            // the whole browser over something that is not a fault. The lesson
            // is Ollama's; see `OllamaSessionCookie.normalize`.
            guard seen.insert(name).inserted else { continue }
            kept.append("\(name)=\(value)")
        }
        guard required.allSatisfy({ seen.contains($0) }) else {
            throw XiaomiMiMoError.invalidCookie
        }
        return kept.joined(separator: "; ")
    }
}

/// A read-only adapter for the console's account routes. Kept apart from the
/// app so the envelope and the parsing are testable without a session.
struct XiaomiMiMoClient: Sendable {
    static let host = "platform.xiaomimimo.com"
    static let base = URL(string: "https://platform.xiaomimimo.com/api/v1")!
    /// Where somebody is sent to sign in, and the page the console fetches
    /// these from — so the `Referer` is true rather than invented.
    static let consoleURL = URL(string: "https://platform.xiaomimimo.com/#/console/balance")!

    /// Optional only as a test seam. Production resolves the shared session at
    /// request time so a proxy change cannot leave a client holding the one
    /// that was invalidated.
    var session: URLSession?

    /// The Coding Plan half: `tokenPlan/detail` and `tokenPlan/usage`.
    ///
    /// A missing plan is a complete answer (nil) rather than a throw — the
    /// account buys tokens by the yuan and `xiaomiAPI` is the row for that.
    func fetchPlan(cookie: String) async throws -> XiaomiMiMoSnapshot.Plan? {
        let header = try XiaomiMiMoCookie.normalize(cookie)

        // **What each route threw is kept, not discarded.** `try?` here made
        // every status `get` bothers to classify unreachable: an HTTP 401, a
        // 429 and a 500 all became three nils and came out as "the reply could
        // not be read". A session that needs signing in again has to say so.
        async let planDetail = outcome(of: "tokenPlan/detail", cookie: header)
        async let planUsage = outcome(of: "tokenPlan/usage", cookie: header)

        let routes = await [planDetail, planUsage]
        let detailData = try? routes[0].get()
        let usageData = try? routes[1].get()

        // Every route is the same envelope, so one expired session shows up on
        // both. Reported from whichever answered rather than from a third
        // request made only to ask.
        for data in [detailData, usageData].compactMap({ $0 }) {
            if let refusal = Self.refusal(in: data) { throw refusal }
        }

        if detailData == nil, usageData == nil {
            throw Self.worst(of: routes)
        }

        return Self.parsePlan(detail: detailData, usage: usageData)
    }

    /// The prepaid purse half: the `balance` route alone. That money is the
    /// whole reading of `xiaomiAPI`, so a route that does not answer is the
    /// call's failure rather than a missing line on somebody else's card.
    ///
    /// Nil is a **complete answer** — the session worked and the account
    /// holds no purse at all — and is distinct from a balance of zero, which
    /// is money. Production maps nil to `.xiaomiNoBalance`.
    func fetchBalance(cookie: String) async throws -> (amount: Double, currency: String)? {
        let header = try XiaomiMiMoCookie.normalize(cookie)
        let data: Data
        do {
            data = try await get("balance", cookie: header)
        } catch let error as XiaomiMiMoError {
            throw error
        } catch is CancellationError {
            throw XiaomiMiMoError.unreachable
        } catch {
            // A transport failure — no network, DNS, TLS, a timeout. **Not
            // `unreadableReply`**, which means something came back and could
            // not be parsed; `ConnectionRemedy` offers Setup help for that and
            // Retry for this, and a dropped wifi connection should not send
            // somebody to the documentation.
            throw XiaomiMiMoError.unreachable
        }
        if let refusal = Self.refusal(in: data) { throw refusal }
        return try Self.parseBalance(data)
    }

    /// A combined read for tests and anything that still wants both halves
    /// from one call. Production fetches each product through its own route
    /// set so a plan failure does not take the purse down with it.
    func fetch(cookie: String) async throws -> XiaomiMiMoSnapshot {
        let header = try XiaomiMiMoCookie.normalize(cookie)

        async let planDetail = outcome(of: "tokenPlan/detail", cookie: header)
        async let planUsage = outcome(of: "tokenPlan/usage", cookie: header)
        async let balance = outcome(of: "balance", cookie: header)

        let routes = await [planDetail, planUsage, balance]
        let detailData = try? routes[0].get()
        let usageData = try? routes[1].get()
        let balanceData = try? routes[2].get()

        for data in [detailData, usageData, balanceData].compactMap({ $0 }) {
            if let refusal = Self.refusal(in: data) { throw refusal }
        }

        if detailData == nil, usageData == nil, balanceData == nil {
            throw Self.worst(of: routes)
        }

        let money = balanceData.flatMap { try? Self.parseBalance($0) }
        return XiaomiMiMoSnapshot(
            plan: Self.parsePlan(detail: detailData, usage: usageData),
            balance: money?.amount,
            currency: money?.currency)
    }

    /// One route's answer, kept whichever way it went.
    private func outcome(of path: String, cookie: String) async -> Result<Data, XiaomiMiMoError> {
        do {
            return .success(try await get(path, cookie: cookie))
        } catch let error as XiaomiMiMoError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(.unreachable)
        } catch {
            // A transport failure — no network, DNS, TLS, a timeout. **Not
            // `unreadableReply`**, which means something came back and could
            // not be parsed; `ConnectionRemedy` offers Setup help for that and
            // Retry for this, and a dropped wifi connection should not send
            // somebody to the documentation.
            return .failure(.unreachable)
        }
    }

    /// The most actionable of several failures.
    ///
    /// A session that has to be signed in again outranks a timeout: if one
    /// route says the login is refused and another merely timed out, the login
    /// is the thing to tell the reader about.
    private static func worst(of routes: [Result<Data, XiaomiMiMoError>]) -> XiaomiMiMoError {
        let failures = routes.compactMap { route -> XiaomiMiMoError? in
            guard case .failure(let error) = route else { return nil }
            return error
        }
        let rank: (XiaomiMiMoError) -> Int = { error in
            switch error {
            case .sessionExpired, .missingCookie, .invalidCookie: 3
            case .rateLimited, .serverError: 2
            case .unreachable: 1
            case .noPlan, .unreadableReply: 0
            }
        }
        return failures.max { rank($0) < rank($1) } ?? .unreachable
    }

    private func get(_ path: String, cookie: String) async throws -> Data {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://\(Self.host)", forHTTPHeaderField: "Origin")
        request.setValue(Self.consoleURL.absoluteString, forHTTPHeaderField: "Referer")

        let (data, response) = try await (session ?? NetworkSession.shared).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XiaomiMiMoError.unreadableReply("no HTTP response")
        }
        switch http.statusCode {
        case 200: return data
        // An expired session is answered by redirecting the API call at the
        // login flow, so a 3xx here is a sign-in problem rather than a moved
        // endpoint. `URLSession` follows redirects, so this is only reached
        // when one was not followed.
        case 300..<400, 401: throw XiaomiMiMoError.sessionExpired
        case 403: throw XiaomiMiMoError.sessionExpired
        case 429: throw XiaomiMiMoError.rateLimited
        case 500...599: throw XiaomiMiMoError.serverError
        default: throw XiaomiMiMoError.unreadableReply("HTTP \(http.statusCode)")
        }
    }

    /// The envelope's own verdict. The platform answers a refused session with
    /// **HTTP 200** and a code in the body, which is the shape that had Zhipu
    /// reporting "the service returned an error" for the commonest mistake
    /// there is — so the body is read on every route, not just the failing one.
    private static func refusal(in data: Data) -> XiaomiMiMoError? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        switch envelope.code {
        case 0: return nil
        case 401, 403: return .sessionExpired
        default: return nil
        }
    }

    static func parsePlan(detail: Data?, usage: Data?) -> XiaomiMiMoSnapshot.Plan? {
        let decoder = JSONDecoder()
        // **The envelope first, as `parseBalance` does.** The platform answers
        // over HTTP 200 whatever happened, so a body whose `code` is not zero
        // is a failure wearing a success's clothes. Read without this, a
        // `code` 500 carrying an empty `items` came out as "no Coding Plan on
        // this account" — a fault reported as a subscription.
        let usagePayload = usage
            .flatMap { try? decoder.decode(PlanUsage.self, from: $0) }
            .flatMap { $0.code == 0 ? $0 : nil }
        // `monthUsage.items` is a list because the console draws a row per
        // bucket; the plan's own allowance is the first. **Null** is what a
        // live no-plan account answers — `[]` was the guess written to the
        // contract — and either spelling lands here, decoding to nil rather
        // than to a zero: a ring at 0% would say "you have a full month
        // left". An array type that threw on null reached the right answer
        // only by luck of the `try?` above it.
        guard let item = usagePayload?.data?.monthUsage?.items?.first, item.limit > 0 else {
            return nil
        }

        let detailPayload = detail
            .flatMap { try? decoder.decode(PlanDetail.self, from: $0) }
            .flatMap { $0.code == 0 ? $0 : nil }?.data
        // An expired plan reports last month's numbers until it is renewed.
        // Those are not a current allowance, so they are not drawn.
        if detailPayload?.expired == true { return nil }

        // `planName` beside `planCode` on a live reply: the platform keeps a
        // display name and an identifier as separate fields, and Pulse shows
        // names — `planCode` stays as the fallback for a reply that carries
        // only that one.
        return .init(used: item.used,
                     limit: item.limit,
                     periodEnd: detailPayload?.currentPeriodEnd.flatMap(Self.date(from:)),
                     name: detailPayload?.planName ?? detailPayload?.planCode)
    }

    static func parseBalance(_ data: Data) throws -> (amount: Double, currency: String)? {
        let payload = try JSONDecoder().decode(Balance.self, from: data)
        guard payload.code == 0, let body = payload.data,
              let amount = Double(body.balance) else { return nil }
        let currency = body.currency.trimmingCharacters(in: .whitespaces)
        guard !currency.isEmpty else { return nil }
        return (amount, currency)
    }

    /// The console's own format, in UTC. Not ISO-8601, so `ISO8601DateFormatter`
    /// returns nil on it and the card silently loses its reset.
    static func date(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: text)
    }

    private struct Envelope: Decodable { let code: Int }

    private struct PlanDetail: Decodable {
        let code: Int
        let data: Body?
        struct Body: Decodable {
            let planCode: String?
            /// Beside `planCode` on a live reply; null while no plan runs.
            let planName: String?
            let currentPeriodEnd: String?
            let expired: Bool?
        }
    }

    private struct PlanUsage: Decodable {
        let code: Int
        let data: Body?
        struct Body: Decodable { let monthUsage: Month? }
        struct Month: Decodable {
            /// Null, not `[]`, when the account runs no plan — seen on a
            /// live reply, where a non-optional array used to throw and
            /// reach "no plan" only through `try?` swallowing it.
            let items: [Item]?
        }
        struct Item: Decodable {
            let name: String?
            let used: Int
            let limit: Int
        }
    }

    private struct Balance: Decodable {
        let code: Int
        let data: Body?
        struct Body: Decodable {
            let balance: String
            let currency: String
        }
    }
}

/// The Coding Plan ring: one monthly token allowance, drawn against its own
/// reported limit. Money is **not** carried here — the prepaid purse is
/// `xiaomiAPI`'s whole job, so this reading has no `creditBalance` and no
/// "warn below" line.
struct XiaomiMiMoUsageService: Sendable {
    let cookie: String?
    var client = XiaomiMiMoClient()

    func fetch() async -> ProviderUsage {
        guard let cookie, !cookie.isEmpty else {
            return .unavailable(.xiaomiMiMo, reason: .xiaomiSessionMissing)
        }
        do {
            let plan = try await client.fetchPlan(cookie: cookie)
            return Self.reading(from: plan)
        } catch let error as XiaomiMiMoError {
            return .unavailable(.xiaomiMiMo, reason: Self.reason(for: error))
        } catch {
            return .unavailable(.xiaomiMiMo, reason: .unreachable)
        }
    }

    static func reason(for error: XiaomiMiMoError) -> ProviderUsage.Unavailability {
        switch error {
        case .missingCookie, .invalidCookie: .xiaomiSessionMissing
        case .sessionExpired: .xiaomiSessionExpired
        case .noPlan: .xiaomiNoCodingPlan
        case .rateLimited: .rateLimited
        case .serverError: .serverError
        case .unreadableReply: .unreadableReply
        case .unreachable: .unreachable
        }
    }

    /// What one plan reply says the panel should draw.
    ///
    /// **A session that answered is not the same as an account with a plan.**
    /// An account that buys tokens by the yuan has no Coding Plan; that is a
    /// complete answer about the subscription and the money half lives on
    /// `xiaomiAPI`, so this row says `.xiaomiNoCodingPlan` rather than
    /// drawing an empty live reading.
    static func reading(
        from plan: XiaomiMiMoSnapshot.Plan?, now: Date = Date()
    ) -> ProviderUsage {
        guard let plan else {
            return .unavailable(.xiaomiMiMo, reason: .xiaomiNoCodingPlan)
        }
        return .init(account: AccountKey(.xiaomiMiMo),
                     windows: [planWindow(plan)],
                     observedAt: now,
                     state: .live,
                     plan: plan.name,
                     creditBalance: nil,
                     creditRemaining: nil)
    }

    /// The Coding Plan's month, as the one window whose length nobody stated.
    private static func planWindow(_ plan: XiaomiMiMoSnapshot.Plan) -> UsageWindow {
        UsageWindow(
            id: "xiaomi.plan",
            kind: .monthly,
            scope: nil,
            usedFraction: Double(plan.used) / Double(plan.limit),
            // Thirty days is a **sort key, not a reported length**. The
            // platform states when the period ends and never how long it
            // is, and a billing month is not a fixed number of seconds —
            // so `reportsLength` is false and the window-clock arc and the
            // forecast leave it alone rather than dividing by a number
            // nobody stated. Copilot's calendar month is carried the same
            // way; see `UsageWindow.reportsLength`.
            windowSeconds: 30 * 86_400,
            resetsAt: plan.periodEnd,
            reportsLength: false,
            isExhausted: plan.used >= plan.limit)
    }
}

/// Xiaomi's prepaid purse — the yuan-metered API balance — as its own ring.
///
/// Split out of the Coding Plan row because one account sells two things and
/// a single ring can only show one of them. The platform reports money and
/// **no allowance** to take a percentage of, so the denominator is the
/// highest balance Pulse has watched since it last rose — DeepSeek's rule,
/// carried across whole and labelled as an estimate wherever it is shown.
struct XiaomiAPIUsageService: Sendable {
    let cookie: String?
    var client = XiaomiMiMoClient()

    /// Where this account's watched balance peaks are filed. Its own scope —
    /// and so its own file — because DeepSeek reads the same mechanism and
    /// both accounts can be priced in CNY: a peak one provider watched must
    /// never become the denominator of the other's money. Distinct from the
    /// plan row's history as well, which no longer measures money at all.
    static let baselineScope = "xiaomiapi"

    func fetch() async -> ProviderUsage {
        guard let cookie, !cookie.isEmpty else {
            return .unavailable(.xiaomiAPI, reason: .xiaomiSessionMissing)
        }
        do {
            guard let purse = try await client.fetchBalance(cookie: cookie) else {
                // The session worked and the account holds neither money nor
                // a zero — a complete answer about the purse, not a fault.
                return .unavailable(.xiaomiAPI, reason: .xiaomiNoBalance)
            }
            // Advance the watched peak here, on success, before the reading is
            // built — the same place and the same order `DeepSeekUsageService`
            // does it, so `reading(from:peak:)` can stay a pure mapping and
            // the tests never write into the marks of whoever runs them.
            return Self.reading(from: purse, peak: Self.advanceBaseline(for: purse))
        } catch let error as XiaomiMiMoError {
            return .unavailable(.xiaomiAPI, reason: XiaomiMiMoUsageService.reason(for: error))
        } catch {
            return .unavailable(.xiaomiAPI, reason: .unreachable)
        }
    }

    /// What this reading's balance does to the watched peak, and the
    /// denominator it leaves behind.
    ///
    /// A balance that went **up** can only be a top-up, and that resets the
    /// mark; anything else leaves it alone. The first sight sets it, so the
    /// balance row reads 0% until money is actually spent — a true statement
    /// about what Pulse has seen rather than a figure anyone made up.
    static func advanceBaseline(
        for purse: (amount: Double, currency: String), at now: Date = Date()
    ) -> Double {
        var marks = DeepSeekBaseline.marks(scope: baselineScope)
        let mark = DeepSeekBaseline.advanced(
            marks[purse.currency], seeing: purse.amount, at: now
        )
        if marks[purse.currency] != mark {
            marks[purse.currency] = mark
            DeepSeekBaseline.store(marks, scope: baselineScope)
        }
        return mark.peak
    }

    /// What one purse reading says the panel should draw.
    ///
    /// The money is always carried — zero included, because an account that
    /// has spent everything is not one Pulse failed to read. The ring needs a
    /// peak to measure against; with no mark yet the first balance *becomes*
    /// the mark and the row reads 0% until money is spent. A peak of zero —
    /// an account that has never held any credit — draws no row at all.
    static func reading(
        from purse: (amount: Double, currency: String), now: Date = Date(), peak: Double
    ) -> ProviderUsage {
        var windows: [UsageWindow] = []
        if let fraction = DeepSeekBaseline.usedFraction(balance: purse.amount, peak: peak) {
            windows.append(UsageWindow(
                id: "xiaomi.balance",
                kind: .balance,
                // Not the scope: `--json` promises that reads the same in every
                // language, and the wording that marks this inferred is localized.
                scope: nil,
                usedFraction: fraction,
                // A prepaid balance does not turn over: no reset and no length.
                windowSeconds: 30 * 86_400,
                resetsAt: nil,
                reportsLength: false,
                estimate: .sinceTopUp))
        }

        return .init(account: AccountKey(.xiaomiAPI),
                     windows: windows,
                     observedAt: now,
                     state: .live,
                     plan: nil,
                     creditBalance: Self.money(purse),
                     creditRemaining: .init(amount: purse.amount, currency: purse.currency))
    }

    /// The exact figure as a display string. The window is the glance; this
    /// is the number behind it, and the one a "warn below" line compares.
    private static func money(_ purse: (amount: Double, currency: String)) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = purse.currency
        formatter.locale = LocalizationSource.locale
        return formatter.string(from: NSNumber(value: purse.amount))
            ?? "\(purse.amount) \(purse.currency)"
    }
}

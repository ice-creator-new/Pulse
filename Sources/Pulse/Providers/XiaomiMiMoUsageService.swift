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
/// **Two things on one account, each drawn against its own figure.** The
/// account carries a monthly token allowance bought as a plan and a prepaid
/// cash balance for anything past it. The plan's percentage is the platform's
/// own; the balance has no allowance behind it, so its denominator is the
/// highest balance Pulse has watched since it last rose — DeepSeek's rule,
/// carried across whole and labelled as an estimate wherever it is shown.
/// An account with no plan is not a fault; it is an account that buys tokens
/// by the yuan, and it says so — or draws its money, when it has any.
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

    func fetch(cookie: String) async throws -> XiaomiMiMoSnapshot {
        let header = try XiaomiMiMoCookie.normalize(cookie)

        // The plan is what the ring is for, so its failure is the call's
        // failure. The balance is a line on the card, so a balance route that
        // does not answer costs that line and nothing else.
        //
        // **What each route threw is kept, not discarded.** `try?` here made
        // every status `get` bothers to classify unreachable: an HTTP 401, a
        // 429 and a 500 all became three nils and came out as "the reply could
        // not be read". A session that needs signing in again has to say so.
        async let planDetail = outcome(of: "tokenPlan/detail", cookie: header)
        async let planUsage = outcome(of: "tokenPlan/usage", cookie: header)
        async let balance = outcome(of: "balance", cookie: header)

        let routes = await [planDetail, planUsage, balance]
        let detailData = try? routes[0].get()
        let usageData = try? routes[1].get()
        let balanceData = try? routes[2].get()

        // Every route is the same envelope, so one expired session shows up on
        // all three. Reported from whichever answered rather than from a
        // fourth request made only to ask.
        for data in [detailData, usageData, balanceData].compactMap({ $0 }) {
            if let refusal = Self.refusal(in: data) { throw refusal }
        }

        // Nothing answered. Report what the routes actually said rather than
        // one blanket sentence: the worst of the three, so a session problem
        // outranks a timeout and the reader is sent to the right remedy.
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

struct XiaomiMiMoUsageService: Sendable {
    let cookie: String?
    var client = XiaomiMiMoClient()

    /// Where this account's watched balance peaks are filed. Its own scope —
    /// and so its own file — because DeepSeek reads the same mechanism and
    /// both accounts can be priced in CNY: a peak one provider watched must
    /// never become the denominator of the other's money.
    static let baselineScope = "xiaomimimo"

    func fetch() async -> ProviderUsage {
        guard let cookie, !cookie.isEmpty else {
            return .unavailable(.xiaomiMiMo, reason: .xiaomiSessionMissing)
        }
        do {
            let snapshot = try await client.fetch(cookie: cookie)
            // Advance the watched peak here, on success, before the reading is
            // built — the same place and the same order `DeepSeekUsageService`
            // does it, so `reading(from:peak:)` can stay a pure mapping and
            // the tests never write into the marks of whoever runs them.
            return Self.reading(from: snapshot, peak: Self.advanceBaseline(for: snapshot))
        } catch let error as XiaomiMiMoError {
            let reason: ProviderUsage.Unavailability = switch error {
            case .missingCookie, .invalidCookie: .xiaomiSessionMissing
            case .sessionExpired: .xiaomiSessionExpired
            case .noPlan: .xiaomiNoCodingPlan
            case .rateLimited: .rateLimited
            case .serverError: .serverError
            case .unreadableReply: .unreadableReply
            case .unreachable: .unreachable
            }
            return .unavailable(.xiaomiMiMo, reason: reason)
        } catch {
            return .unavailable(.xiaomiMiMo, reason: .unreachable)
        }
    }

    /// What this reading's balance does to the watched peak, and the
    /// denominator it leaves behind.
    ///
    /// A balance that went **up** can only be a top-up, and that resets the
    /// mark; anything else leaves it alone. The first sight sets it, so the
    /// balance row reads 0% until money is actually spent — a true statement
    /// about what Pulse has seen rather than a figure anyone made up.
    ///
    /// Nil when the balance route did not answer: no money means nothing to
    /// measure and nothing written. Production is the only caller — see
    /// `fetch()` above for why this does not live in `reading(from:peak:)`.
    static func advanceBaseline(
        for snapshot: XiaomiMiMoSnapshot, at now: Date = Date()
    ) -> Double? {
        guard let purse = remaining(snapshot) else { return nil }

        var marks = DeepSeekBaseline.marks(scope: baselineScope)
        let mark = DeepSeekBaseline.advanced(marks[purse.currency], seeing: purse.amount, at: now)
        if marks[purse.currency] != mark {
            marks[purse.currency] = mark
            DeepSeekBaseline.store(marks, scope: baselineScope)
        }
        return mark.peak
    }

    /// What one snapshot of the console says the panel should draw.
    ///
    /// **A session that answered is not the same as an account with a plan.**
    /// An account that buys tokens by the yuan has no Coding Plan and still
    /// has money on it — that money is a whole reading on its own, and an
    /// account with a plan has money on it too, for whatever runs past the
    /// allowance. So the balance is a window in its own right rather than a
    /// line that only appears when the plan is missing, and an account with
    /// neither still says so rather than drawing an empty live reading.
    ///
    /// `peak` is the watched balance peak for this account's currency (see
    /// `advanceBaseline(for:)`), nil where there is no balance to measure.
    /// A balance of zero is still money: it keeps `creditBalance` and the
    /// card's plain figure even though there is no window to draw — an
    /// account that has spent everything is not one Pulse failed to read.
    static func reading(
        from snapshot: XiaomiMiMoSnapshot, now: Date = Date(), peak: Double?
    ) -> ProviderUsage {
        let money = Self.money(snapshot)
        var windows = snapshot.plan.map { [Self.planWindow($0)] } ?? []
        if let window = Self.balanceWindow(snapshot, peak: peak) { windows.append(window) }

        // Nothing to draw and nothing to show: no plan and no balance is
        // still a complete answer about the subscription, not a fault.
        guard !windows.isEmpty || money != nil else {
            return .unavailable(.xiaomiMiMo, reason: .xiaomiNoCodingPlan)
        }

        return .init(account: AccountKey(.xiaomiMiMo),
                     windows: windows,
                     observedAt: now,
                     state: .live,
                     plan: snapshot.plan?.name,
                     creditBalance: money,
                     creditRemaining: Self.remaining(snapshot))
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

    /// The prepaid balance as a row of its own, measured against the highest
    /// balance Pulse has watched in this currency since it last rose.
    ///
    /// **The denominator is a figure Pulse watched, not one it made up** — the
    /// platform reports money and no allowance to take a percentage of, which
    /// is the hole DeepSeek's `sinceTopUp` fills the same way. The row carries
    /// `estimate`, so the card and `--json` both say the figure was inferred
    /// rather than reporting it as the platform's.
    ///
    /// What it costs is the first run: no mark yet means the first balance
    /// *becomes* the mark and the row reads 0% until money is spent. A peak of
    /// zero — an account that has never held any credit — draws no row at all:
    /// never having had money is not the same as having spent it. Nil `peak`
    /// (no balance route answered) is neither of those; the money is carried
    /// as `creditBalance` and no fraction is drawn against nothing.
    ///
    /// **The plan draws first and the rail picks the fuller of the two** — the
    /// usual headline rule, so whichever of month-tokens or money will bite
    /// first gets the ring, and the other keeps its row on the card.
    private static func balanceWindow(
        _ snapshot: XiaomiMiMoSnapshot, peak: Double?
    ) -> UsageWindow? {
        guard let purse = remaining(snapshot), let peak,
              let fraction = DeepSeekBaseline.usedFraction(balance: purse.amount, peak: peak)
        else { return nil }

        return UsageWindow(
            id: "xiaomi.balance",
            kind: .balance,
            // Not the scope: `--json` promises that reads the same in every
            // language, and the wording that marks this inferred is localized.
            scope: nil,
            usedFraction: fraction,
            // A prepaid balance does not turn over, so there is no reset and no
            // length — the seconds exist to sort the row under the month.
            windowSeconds: 30 * 86_400,
            resetsAt: nil,
            reportsLength: false,
            estimate: .sinceTopUp)
    }

    /// The prepaid balance as a line on the card, beside the row that draws a
    /// fraction of it. A display string for the body; `remaining(_:)` carries
    /// the same figure as a number, and `balanceWindow(_:peak:)` is what turns
    /// it into a row of its own.
    ///
    /// This is the **exact** figure and the window is the glance: the row
    /// needed a denominator Pulse could stand behind, the card did not.
    private static func money(_ snapshot: XiaomiMiMoSnapshot) -> String? {
        guard let balance = snapshot.balance, let currency = snapshot.currency else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = LocalizationSource.locale
        return formatter.string(from: NSNumber(value: balance))
    }

    /// The same figure as a number and a currency: the key the watched peak
    /// is filed under (one per currency, in this provider's own file), and —
    /// through `reportsSpendableBalance` — the thing a "warn below" line
    /// compares against. Nil where the route did not answer, which is the
    /// line between no balance and a balance of zero.
    private static func remaining(_ snapshot: XiaomiMiMoSnapshot) -> ProviderUsage.CreditAmount? {
        guard let balance = snapshot.balance, let currency = snapshot.currency else { return nil }
        return .init(amount: balance, currency: currency)
    }
}

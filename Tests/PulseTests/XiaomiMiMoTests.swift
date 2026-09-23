import Foundation
import Testing
@testable import Pulse

/// Xiaomi's console is read with a browser session, and answers a refused one
/// with **HTTP 200** and a code in the body. Both halves of that are where this
/// provider can go quietly wrong: a credential assembled from whatever a
/// browser happened to store, and a failure that looks like a success to
/// anything reading the status line.
@Suite("Xiaomi Coding Plan")
struct XiaomiMiMoTests {
    private static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }

    // MARK: - The credential

    /// The session is built from a browser store that also holds analytics,
    /// preferences and whatever the site adds next. Only the named cookies may
    /// leave the process.
    @Test("Only the console's own cookies are kept")
    func normalizeKeepsOnlyWhatIsNeeded() throws {
        let header = """
        _ga=GA1.1.99; api-platform_serviceToken=abc123; \
        userId=42; sensorsdata=xyz; api-platform_ph=ph1
        """
        let kept = try XiaomiMiMoCookie.normalize(header)
        #expect(kept.contains("api-platform_serviceToken=abc123"))
        #expect(kept.contains("userId=42"))
        #expect(kept.contains("api-platform_ph=ph1"))
        #expect(!kept.contains("_ga"))
        #expect(!kept.contains("sensorsdata"))
    }

    /// Either of the two required names missing is a session that cannot be
    /// used, and saying so beats sending a request that comes back as a
    /// mysterious refusal.
    @Test("Both required cookies or nothing")
    func normalizeNeedsBothRequiredNames() {
        #expect(throws: XiaomiMiMoError.invalidCookie) {
            try XiaomiMiMoCookie.normalize("api-platform_serviceToken=abc123; _ga=1")
        }
        #expect(throws: XiaomiMiMoError.invalidCookie) {
            try XiaomiMiMoCookie.normalize("userId=42; _ga=1")
        }
    }

    /// A header pasted out of a network tab, `Cookie:` prefix and all.
    @Test("A pasted header is taken as pasted")
    func normalizeAcceptsAPastedHeader() throws {
        let kept = try XiaomiMiMoCookie.normalize("Cookie: api-platform_serviceToken=t; userId=1")
        #expect(kept == "api-platform_serviceToken=t; userId=1")
    }

    /// A value carrying a newline would end the header and start whatever came
    /// after it as a fresh one.
    @Test("A control character is refused, not forwarded")
    func normalizeRefusesInjection() {
        #expect(throws: XiaomiMiMoError.invalidCookie) {
            try XiaomiMiMoCookie.normalize("api-platform_serviceToken=a\r\nX-Evil: 1; userId=1")
        }
    }

    /// Every browser store routinely holds a host-only row and a domain row
    /// for one name. Throwing on the second discarded the whole browser — the
    /// mistake Ollama's normalizer already had to learn.
    @Test("A repeated cookie is not a broken one")
    func normalizeTakesTheFirstOfADuplicate() throws {
        let kept = try XiaomiMiMoCookie.normalize(
            "api-platform_serviceToken=first; userId=1; api-platform_serviceToken=second")
        #expect(kept.contains("api-platform_serviceToken=first"))
        #expect(!kept.contains("second"))
    }

    /// Chrome quotes this platform's `serviceToken` on the wire, so the
    /// header pasted out of a network tab arrives with a matched pair of
    /// quotes around the value — and that paste is a documented way in. RFC
    /// 6265 spells a cookie-value exactly that way, so the pair is stripped
    /// rather than refused, and the bare value is what leaves the process:
    /// the live route accepts it unquoted.
    @Test("A quoted value from a pasted header is taken as pasted")
    func normalizeStripsSurroundingQuotes() throws {
        let kept = try XiaomiMiMoCookie.normalize(
            "Cookie: api-platform_serviceToken=\"t\"; userId=\"42\"; _ga=x")
        #expect(kept == "api-platform_serviceToken=t; userId=42")
    }

    /// The stripping is of a *matched pair surrounding the value* and
    /// nothing more. A quote inside the value is structure this parser does
    /// not model, in a header assembled from an arbitrary string.
    @Test("A quote that is not wrapping the value is refused")
    func normalizeRefusesAMidValueQuote() {
        #expect(throws: XiaomiMiMoError.invalidCookie) {
            try XiaomiMiMoCookie.normalize("api-platform_serviceToken=ab\"c; userId=1")
        }
    }

    // MARK: - The reply

    @Test("A plan reports what is used out of what was bought")
    func planIsReadFromBothRoutes() throws {
        let plan = try #require(XiaomiMiMoClient.parsePlan(
            detail: try Self.fixture("xiaomi-plan-detail"),
            usage: try Self.fixture("xiaomi-plan-usage")))
        #expect(plan.used == 3_750_000)
        #expect(plan.limit == 10_000_000)
        // `planName` sits beside `planCode` on a live reply, and the name is
        // what Settings shows — `planCode` alone would have shown an
        // identifier where every other provider shows a name.
        #expect(plan.name == "Coding Pro")
        // The console's own format, which is not ISO-8601 — parsed with a
        // formatter that knows that, or the card silently loses its reset.
        #expect(plan.periodEnd == XiaomiMiMoClient.date(from: "2026-10-01 00:00:00"))
        #expect(plan.periodEnd != nil)
    }

    /// An account with no plan buys tokens by the yuan. Nil rather than a
    /// zero: a ring at 0% would read as a full month nobody has.
    @Test("No plan is nothing to draw, not an empty plan")
    func noPlanIsNil() throws {
        #expect(XiaomiMiMoClient.parsePlan(
            detail: try Self.fixture("xiaomi-plan-detail"),
            usage: try Self.fixture("xiaomi-no-plan")) == nil)
    }

    /// The fixture pins what a live no-plan account actually answers —
    /// `items: null`, not `[]` — so the other spelling gets its own line:
    /// both must decode to "no plan" rather than one of them throwing into
    /// the same nil by accident.
    @Test("An empty bucket list is also no plan")
    func emptyItemsIsNoPlan() throws {
        let usage = Data("""
        {"code":0,"message":"","data":{"monthUsage":{"percent":0,"items":[]},"usage":null}}
        """.utf8)
        #expect(XiaomiMiMoClient.parsePlan(detail: nil, usage: usage) == nil)
    }

    /// A lapsed plan keeps reporting last month's figures until it renews.
    @Test("An expired plan is not a current allowance")
    func expiredPlanIsNotDrawn() throws {
        let detail = Data("""
        {"code":0,"data":{"planCode":"coding-pro","currentPeriodEnd":"2026-08-01 00:00:00","expired":true}}
        """.utf8)
        #expect(XiaomiMiMoClient.parsePlan(
            detail: detail, usage: try Self.fixture("xiaomi-plan-usage")) == nil)
    }

    /// The usage route alone is enough for a ring. The detail route only adds
    /// the reset and the plan's name, so losing it costs those and not the row.
    @Test("The plan survives losing the detail route")
    func planWorksWithoutDetail() throws {
        let plan = try #require(XiaomiMiMoClient.parsePlan(
            detail: nil, usage: try Self.fixture("xiaomi-plan-usage")))
        #expect(plan.used == 3_750_000)
        #expect(plan.periodEnd == nil)
        #expect(plan.name == nil)
    }

    @Test("The balance is read with its currency")
    func balanceIsReadWithItsCurrency() throws {
        let money = try #require(try XiaomiMiMoClient.parseBalance(try Self.fixture("xiaomi-balance")))
        #expect(money.amount == 42.75)
        #expect(money.currency == "CNY")
    }

    /// The platform puts a refused session inside an ordinary HTTP 200. Read
    /// as a success it would come out as "no plan on this account", which
    /// sends somebody to look at their subscription instead of at their login.
    @Test("A refusal inside a 200 is not read as an answer")
    func signedOutEnvelopeIsNotAPlan() throws {
        let data = try Self.fixture("xiaomi-signed-out")
        #expect(XiaomiMiMoClient.parsePlan(detail: data, usage: data) == nil)
        #expect(try XiaomiMiMoClient.parseBalance(data) == nil)
    }

    /// The envelope is read before the payload, on every route.
    ///
    /// A non-zero `code` over an HTTP 200 is a failure wearing a success's
    /// clothes. Read without checking it, a `code` 500 came out as "no Coding
    /// Plan on this account" — a fault reported as a subscription, which
    /// `UsageAlerts` then classes as an answer and uses to clear an outage.
    @Test("A non-zero code is not a plan, whatever the payload says")
    func nonZeroCodeIsNotAPlan() throws {
        let broken = Data("""
        {"code":500,"message":"internal error","data":{"monthUsage":{"percent":0,
        "items":[{"name":"Coding Plan","used":1,"limit":100,"percent":1}]}}}
        """.utf8)
        #expect(XiaomiMiMoClient.parsePlan(detail: nil, usage: broken) == nil,
                "a 500 envelope was read as an allowance")
    }

    /// The detail route's envelope too: a bad one must not contribute a reset
    /// or a plan name to a row built from the usage route.
    @Test("A non-zero detail code contributes nothing")
    func nonZeroDetailCodeIsIgnored() throws {
        let broken = Data("""
        {"code":401,"data":{"planCode":"leaked","currentPeriodEnd":"2026-10-01 00:00:00","expired":false}}
        """.utf8)
        let plan = try #require(XiaomiMiMoClient.parsePlan(
            detail: broken, usage: try Self.fixture("xiaomi-plan-usage")))
        #expect(plan.name == nil)
        #expect(plan.periodEnd == nil)
    }

    // MARK: - What the rail is told

    /// The period's end is reported and its length never is. A length is
    /// carried only so the row sorts, and drawing the window-clock arc from it
    /// would be inventing a figure the provider did not state.
    @Test("The month's length is a sort key, not a reported length")
    func monthlyWindowDoesNotClaimALength() throws {
        let plan = try #require(XiaomiMiMoClient.parsePlan(
            detail: try Self.fixture("xiaomi-plan-detail"),
            usage: try Self.fixture("xiaomi-plan-usage")))
        let window = UsageWindow(
            id: "xiaomi.plan", kind: .monthly, scope: nil,
            usedFraction: Double(plan.used) / Double(plan.limit),
            windowSeconds: 30 * 86_400, resetsAt: plan.periodEnd,
            reportsLength: false, isExhausted: false)
        #expect(!window.reportsLength)
        #expect(window.elapsedFraction() == nil)
    }

    /// The plan draws its ring and carries no money — the prepaid purse is
    /// `xiaomiAPI`'s whole job, so this reading has neither a balance window
    /// nor a `creditBalance` line.
    @Test("A plan draws a window and keeps no money of its own")
    func planReadingIsPlanOnly() throws {
        let plan = try #require(XiaomiMiMoClient.parsePlan(
            detail: Self.fixture("xiaomi-plan-detail"),
            usage: Self.fixture("xiaomi-plan-usage")))
        let reading = XiaomiMiMoUsageService.reading(from: plan)
        #expect(reading.state == .live)
        #expect(reading.windows.count == 1)
        #expect(reading.windows[0].id == "xiaomi.plan")
        #expect(reading.creditBalance == nil)
        #expect(reading.creditRemaining == nil)
        #expect(reading.reportsSomething)
    }

    /// The purse gets a ring of its own once there is a peak to measure it
    /// against — the denominator is something Pulse **watched**, and the row
    /// says so through `estimate`, on screen and in `--json`.
    @Test("The purse draws its own window against the watched peak")
    func balanceDrawsItsOwnWindow() throws {
        let money = try #require(try XiaomiMiMoClient.parseBalance(try Self.fixture("xiaomi-balance")))
        let reading = XiaomiAPIUsageService.reading(from: money, peak: 100)
        #expect(reading.state == .live)
        #expect(reading.windows.map(\.id) == ["xiaomi.balance"])

        let balance = try #require(reading.windows.first)
        #expect(balance.kind == .balance)
        #expect(balance.estimate == .sinceTopUp)
        #expect(balance.usedFraction == (100 - 42.75) / 100)
        // Prepaid credit never turns over: no reset, and no length anyone
        // stated — so the window-clock arc and the forecast leave it alone
        // rather than dividing by the sort key it carries.
        #expect(balance.resetsAt == nil)
        #expect(!balance.reportsLength)
        #expect(balance.elapsedFraction() == nil)
        // And it is never "spent": that word belongs to the provider's own
        // flag, and Xiaomi reports none for money.
        #expect(!balance.isExhausted)
        #expect(reading.creditBalance != nil)
        #expect(reading.creditRemaining?.amount == 42.75)
        #expect(reading.creditRemaining?.currency == "CNY")
    }

    /// An account with money and no Coding Plan: the money *is* the reading
    /// on `xiaomiAPI` — a ring the rail can draw and a figure the low-balance
    /// rule can watch. The plan row separately says it has no plan.
    @Test("Money with no plan is the purse row's whole reading")
    func balanceWithoutPlanIsStillAReading() throws {
        let money = try #require(try XiaomiMiMoClient.parseBalance(try Self.fixture("xiaomi-balance")))
        let reading = XiaomiAPIUsageService.reading(from: money, peak: 100)
        #expect(reading.state == .live)
        #expect(reading.windows.map(\.id) == ["xiaomi.balance"])
        #expect(reading.creditBalance != nil)
        #expect(reading.creditRemaining?.amount == 42.75)
        #expect(reading.reportsSomething)
        // There is money to put a figure against, so Settings offers the
        // "warn below" line — as it does for DeepSeek and Command Code.
        #expect(Provider.xiaomiAPI.reportsSpendableBalance)
        // And it is spent on Xiaomi's servers, where nothing on this Mac
        // moves when it drains — so the refresh wait is capped at the
        // unwatched ceiling instead of sitting on the half-hour one.
        #expect(!Provider.xiaomiAPI.spendingIsWatchedLocally)
        // The plan row no longer carries money at all.
        #expect(!Provider.xiaomiMiMo.reportsSpendableBalance)
    }

    /// A balance of zero is money Pulse read, not a read that failed: no
    /// window — an account whose peak is zero has nothing to measure a
    /// fraction against — but the card's plain figure, the rail's money and
    /// the alert's number are all still there.
    @Test("A balance of zero is still money, not a missing reading")
    func zeroBalanceIsStillAReading() throws {
        let money = try #require(try XiaomiMiMoClient.parseBalance(Data("""
        {"code":0,"message":"","data":{"balance":"0.00","currency":"CNY"}}
        """.utf8)))
        let reading = XiaomiAPIUsageService.reading(from: money, peak: 0)
        #expect(reading.state == .live)
        #expect(reading.windows.isEmpty)
        #expect(reading.creditBalance != nil)
        #expect(reading.creditRemaining?.amount == 0)
        #expect(reading.reportsSomething)
    }

    /// No plan is still the subscription answer on the plan row, not a fault
    /// and not an empty live reading that would draw a blank slot forever.
    @Test("No plan says so on the plan row")
    func neitherPlanNorBalanceIsNoCodingPlan() throws {
        let reading = XiaomiMiMoUsageService.reading(from: nil)
        #expect(reading.state == .unavailable(.xiaomiNoCodingPlan))
        #expect(reading.windows.isEmpty)
        #expect(reading.creditBalance == nil)
        #expect(!reading.reportsSomething)
    }

    /// A session that was never set up and one that went stale are different
    /// sentences, and the difference is what the reader has to do next.
    @Test("A missing session and an expired one are told apart")
    func noSessionIsNotAnExpiredOne() async {
        let usage = await XiaomiMiMoUsageService(cookie: nil).fetch()
        #expect(usage.state == .unavailable(.xiaomiSessionMissing))
        let purse = await XiaomiAPIUsageService(cookie: nil).fetch()
        #expect(purse.state == .unavailable(.xiaomiSessionMissing))
    }

    /// The plan row answers the questions the rest of the app asks of every
    /// case. Missing one is a silent fall-through into somebody else's branch.
    @Test("The plan row is wired up as a session-based one")
    func providerAnswersTheSharedQuestions() {
        let provider = Provider.xiaomiMiMo
        #expect(provider.displayName == "Xiaomi Coding Plan")
        #expect(provider.usesSessionCookie)
        #expect(provider.readsBrowserStorage)
        #expect(provider.keepsOwnCredential)
        #expect(!provider.keepsLocalTranscripts)
        #expect(!provider.hasSourceChoice)
        #expect(provider.soleRoute == nil)
        // The plan's percentage has a real denominator and no money rides
        // along with it — the purse row owns the "warn below" line.
        #expect(!provider.reportsSpendableBalance)
        // Nothing to detect on disk: the session lives in a browser, and a
        // browser is not evidence of an account.
        #expect(!Provider.installedOnThisMac().contains(.xiaomiMiMo))
    }

    /// The purse row is the money half of the same platform: same session
    /// shape, and the one that owns `reportsSpendableBalance`.
    @Test("The purse row is the money half of the same platform")
    func apiProviderAnswersTheSharedQuestions() {
        let provider = Provider.xiaomiAPI
        #expect(provider.displayName == "小米API")
        #expect(provider.usesSessionCookie)
        #expect(provider.readsBrowserStorage)
        #expect(provider.keepsOwnCredential)
        #expect(!provider.keepsLocalTranscripts)
        #expect(provider.reportsSpendableBalance)
        #expect(!provider.spendingIsWatchedLocally)
        #expect(provider.iconResource == Provider.xiaomiMiMo.iconResource)
        #expect(!Provider.installedOnThisMac().contains(.xiaomiAPI))
    }

    /// An icon that is not in the bundle draws nothing, and a ring with no
    /// mark is indistinguishable from one that failed to load. Asked through
    /// the app's own loader, because `Bundle.module` inside a test is the
    /// *test* bundle and would answer nil for every mark there is.
    @Test("The mark loads")
    @MainActor
    func iconResourceLoads() {
        #expect(LobeIconStore.image(named: Provider.xiaomiMiMo.iconResource) != nil,
                "\(Provider.xiaomiMiMo.iconResource).svg does not load")
        #expect(LobeIconStore.image(named: Provider.xiaomiAPI.iconResource) != nil,
                "\(Provider.xiaomiAPI.iconResource).svg does not load")
    }
}

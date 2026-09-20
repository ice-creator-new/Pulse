import Foundation
import Testing
@testable import Pulse

/// The detail card's balance figure: shown until it is switched off,
/// remembered per account, and printed only on the row whose window *is* the
/// balance. The percentage of a purse cannot say whether it is counting ¥5
/// or ¥5,000, which is the whole reason the figure sits beside it — and a
/// plan's percentage has no money behind it to sit there.
@Suite("Balance amount on the card")
struct BalanceAmountPreferenceTests {
    /// A `UserDefaults` domain owned by one test, emptied on the way out.
    /// Never `.standard`: writing there would leave a choice behind for the
    /// app, and two tests could not run beside each other.
    private func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "PulseTests.balanceAmount.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    /// On is the default and off is the choice: a fresh store shows the
    /// money, and it takes an entry to stop it.
    @Test("The figure is shown until it is switched off")
    func shownByDefault() {
        withIsolatedDefaults { defaults in
            #expect(AppSettings.storedShowsBalanceAmounts(in: defaults) == [:])
            let untouched = AppSettings(showsBalanceAmounts: [:])
            #expect(untouched.showsBalanceAmount(AccountKey(.deepSeek)))
            #expect(untouched.showsBalanceAmount(AccountKey(.xiaomiMiMo)))

            // The round trip a launch makes: what was stored is what the
            // next instance is built with.
            AppSettings.storeShowsBalanceAmounts([AccountKey(.deepSeek).id: false], in: defaults)
            let restored = AppSettings(
                showsBalanceAmounts: AppSettings.storedShowsBalanceAmounts(in: defaults))
            #expect(!restored.showsBalanceAmount(AccountKey(.deepSeek)))
        }
    }

    /// One purse's switch does not reach across accounts — two accounts of
    /// one provider are two balances, let alone two providers.
    @Test("One account's switch leaves the others alone")
    func theSwitchIsPerAccount() {
        withIsolatedDefaults { defaults in
            AppSettings.storeShowsBalanceAmounts(
                [AccountKey(.deepSeek).id: false, AccountKey(.xiaomiMiMo).id: false],
                in: defaults)
            let settings = AppSettings(
                showsBalanceAmounts: AppSettings.storedShowsBalanceAmounts(in: defaults))
            #expect(!settings.showsBalanceAmount(AccountKey(.deepSeek)))
            #expect(!settings.showsBalanceAmount(AccountKey(.xiaomiMiMo)))
            #expect(settings.showsBalanceAmount(AccountKey(.commandCode)))
        }
    }

    @Test("The money rides the balance's own row, and only while it is asked for")
    func figureOnlyOnBalanceRows() {
        let balance = UsageWindow(
            id: "x.balance", kind: .balance, scope: nil,
            usedFraction: 0.42, windowSeconds: 30 * 86_400,
            resetsAt: nil, reportsLength: false, isExhausted: false)
        let plan = UsageWindow(
            id: "x.plan", kind: .monthly, scope: nil,
            usedFraction: 0.42, windowSeconds: 30 * 86_400,
            resetsAt: nil, reportsLength: false, isExhausted: false)

        // The row that measures the purse carries the purse's figure.
        #expect(UsageDetailCard.balanceFigure(for: balance, credit: "¥42.75", enabled: true)
                == "¥42.75")
        // A plan's fraction counts tokens; there is no money behind it.
        #expect(UsageDetailCard.balanceFigure(for: plan, credit: "¥42.75", enabled: true) == nil)
        // Switched off, the figure is the percentage alone.
        #expect(UsageDetailCard.balanceFigure(for: balance, credit: "¥42.75", enabled: false)
                == nil)
        // No reported money: nothing invented to print.
        #expect(UsageDetailCard.balanceFigure(for: balance, credit: nil, enabled: true) == nil)
    }
}

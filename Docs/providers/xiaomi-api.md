# 小米API

Xiaomi's prepaid inference purse — the yuan-metered balance on `platform.xiaomimimo.com` — as its own ring.

Split out of [xiaomi-coding-plan.md](xiaomi-coding-plan.md): one account sells two things, a monthly token allowance and money spent past it, and a single ring can only show one of them. This row is the money half. The plan half keeps its own name and its own percentage.

## Place in Pulse

- `Provider.xiaomiAPI`. Display name **小米API**. Icon `xiaomimimo` (shared with the Coding Plan row, the way MiniMax's pair share theirs). Extra accounts: no. Transcripts: no. Spending history: no.
- First run: offered unchecked in the chooser, with no detected hint. A browser on this Mac is no evidence of an account. After choosing it, import a session in Settings.
- `usesAPIKey` is true so Settings draws a credential row; `usesSessionCookie` is true so that row is a **browser session** rather than an API-key paste. The platform's API keys buy inference and answer none of the console's account routes.
- Service: `XiaomiAPIUsageService` in [`XiaomiMiMoUsageService.swift`](../../Sources/Pulse/Providers/XiaomiMiMoUsageService.swift), sharing `XiaomiMiMoClient` and `XiaomiMiMoCookie` with the plan row. Tests: `XiaomiMiMoTests`. Fixtures: `Tests/PulseTests/Fixtures/xiaomi-*.json`.

## Credential

The same browser session as the plan row — `platform.xiaomimimo.com`, `api-platform_serviceToken` + `userId` required. Import it once per row that is enabled; the store is keyed by provider, so enabling both means pasting or reading the same session twice. Cookie filtering, quote stripping and injection checks: [xiaomi-coding-plan.md](xiaomi-coding-plan.md#credential).

## Route

`GET https://platform.xiaomimimo.com/api/v1/balance` — the only money-shaped route on the platform. `data.balance` and `data.currency` arrive as strings; `currency` is the ISO code (`CNY` on the live pass) and `balance` is the total (`cashBalance` + `giftBalance` on that same pass).

A refused session answers **HTTP 200** with `code` 401 or 403 in the body, the same envelope as the plan routes. A reply that carries neither money nor a zero is `.xiaomiNoBalance` — a complete answer about the purse, not a fault. A balance of **zero** is money Pulse read.

## What the rail is told

One window, `xiaomi.balance`, `kind: .balance`, plus `creditBalance` (the exact money, formatted) and `creditRemaining` (amount + currency) so Settings, `--json` and the alert rule always have the figure. The account pane's **Balance amount** row and the Notifications group's **warn below** line ride `reportsSpendableBalance`, which is true here and false on the plan row.

### The denominator is a peak Pulse watched

The platform reports money and **no allowance** to take a percentage of — DeepSeek's hole, filled by DeepSeek's rule: the denominator is the highest balance Pulse has watched in this currency since it last rose, and a balance that goes *up* can only be a top-up, which resets the mark. `estimate` is `.sinceTopUp`, so the card writes the name as "Balance · since top-up" and `--json` reports `estimated: true` with `estimatedFrom: "sinceTopUp"`.

What it costs is the first run: with no mark yet, the first reading *becomes* the mark and the row reads 0% until money is actually spent. A peak of zero — an account that has never held credit — draws no row at all.

Marks live in `xiaomiapi-baseline.json` — **this provider's own file**, one mark per currency. Distinct from DeepSeek's `deepseek-baseline.json` and from the plan row's history, which no longer measures money. The mark is advanced once per **successful** fetch, before `reading(from:peak:)` builds the row.

There is **no basis picker**: `sinceTopUp` is the only denominator this provider can offer.

`reportsSpendableBalance` is **true**, so `spendingIsWatchedLocally` is false and AdaptiveRefresh caps the wait at `unwatchedCeiling` (300s). [../refresh-and-data.md](../refresh-and-data.md)

## Relationship to Xiaomi Coding Plan

| | Xiaomi Coding Plan | 小米API |
|---|---|---|
| Figure | Monthly tokens used / limit | Prepaid money against a watched peak |
| Window id | `xiaomi.plan` | `xiaomi.balance` |
| `reportsSpendableBalance` | no | yes |
| Routes | `tokenPlan/detail`, `tokenPlan/usage` | `balance` |
| Empty account | `.xiaomiNoCodingPlan` | `.xiaomiNoBalance` |

One storefront, two products. Enable whichever the account actually buys — or both, for the account that has a plan *and* a purse for whatever runs past it.

## Unconfirmed

- **A top-up landing.** No live account has watched `balance` *rise* to confirm what `sinceTopUp` assumes: a rise is read as a top-up and resets the peak.
- **A reply carrying neither money nor a zero.** The live pass always had a balance field; `.xiaomiNoBalance` is the contract for the empty shape rather than a measured one.

# Xiaomi Coding Plan

Xiaomi's MiMo open platform, read through the console's own account routes.

**Provenance: [CodexBar](https://github.com/steipete/CodexBar), then the live platform.** The routes, the envelope and the cookie names were first read off CodexBar's implementation and its `docs/mimo.md` — which is where this provider came from — and on **2026-09-21** all three routes were fetched against a real session with the exact request `XiaomiMiMoClient` builds. That pass settled several contract-shaped guesses and pinned their key sets into the fixtures; what it could not settle needs an account with a running plan and is left under [Unconfirmed](#unconfirmed). Both halves: [Measured live](#measured-live-2026-09-21).

## Place in Pulse

- `Provider.xiaomiMiMo`. Icon `xiaomimimo`. Extra accounts: no. Transcripts: no. Spending history: no.
- First run: offered unchecked in the chooser, with no detected hint. A browser on this Mac is no evidence of an account. After choosing it, import a session in Settings. It participates in the enabled-account refresh pass, including the first pass after selection.
- `usesAPIKey` is true so Settings draws a credential row; `usesSessionCookie` is true so that row is a **browser session** rather than an API-key paste. The second one is the point: the platform *does* issue API keys, and they buy inference. None of them answers the console routes below.
- Service: [`XiaomiMiMoUsageService.swift`](../../Sources/Pulse/Providers/XiaomiMiMoUsageService.swift). Tests: `XiaomiMiMoTests`, fixtures `Tests/PulseTests/Fixtures/xiaomi-*.json`.

## The name

**"Xiaomi Coding Plan", not "Xiaomi MiMo".** The platform sells two different things on one account: inference by the yuan to anyone with a key, and a monthly token allowance bought on top of that. The row is named for the second — the thing with a subscription behind it and the thing the buyer signed up for — even though the prepaid balance has a row of its own beside it now. Naming the row for the platform would have it stand for both. CodexBar calls its equivalent "Xiaomi MiMo" because it leads with the balance; this one leads with the plan.

It is the longest name on the rail at eighteen characters, four past "GitHub Copilot", which is what the Settings sidebar was previously sized to. See [`../ui/settings.md`](../ui/settings.md).

## One row, not two

**Asked and answered: this is not another MiniMax.** Two providers on the rail are split into a mainland row and an international one — MiniMax / MiniMax CN, and z.ai / Zhipu — because those really are two storefronts: separate accounts, separate keys, and a key for one refused by the other. That split cost a real bug before it existed (issue #13, an international subscriber's key sent to the mainland service), so the question is worth asking of every Chinese provider added since.

Xiaomi is one storefront:

- The official documentation at `mimo.xiaomi.com`, in **both** its English and its Chinese edition, points the Token Plan at the same `platform.xiaomimimo.com/token-plan`. There is no second console and no region selector.
- No sibling console host resolves — `platform-sgp.xiaomimimo.com` and a bare `xiaomimimo.com` do not connect at all.
- CodexBar's own provider carries one host and no region handling.

`token-plan-cn.xiaomimimo.com` and `token-plan-sgp.xiaomimimo.com` both **do** resolve, which is what prompts the question. They are **inference** endpoints — the base URL a CLI wrapper points at, which is how CodexBar's local-usage fallback uses the `sgp` one — not consoles and not account boundaries. One account reaching whichever is nearer is the opposite of the MiniMax case.

Not verified: whether signing up from outside mainland China lands on this same console. Two editions of the vendor's own documentation serving one URL is the evidence there is. If an overseas account turns out to have its own console, this is the page that was wrong, and the remedy is the second row rather than a region switch inside one — see the reasoning under `Provider.displayName` for why.

## Credential

A browser session for `platform.xiaomimimo.com`, read by [`BrowserCookies`](../../Sources/Pulse/Auth/BrowserCookies.swift) or pasted as a `Cookie:` header — the same two ways in as Ollama's, and the second provider to use that path.

`XiaomiMiMoCookie` keeps **only** these names and discards the rest of the store:

| Cookie | |
|---|---|
| `api-platform_serviceToken` | required |
| `userId` | required |
| `api-platform_ph` | sent when present |
| `api-platform_slh` | sent when present |

Both required names or the header is refused before a request is made. Everything else a browser holds for that host — analytics, preferences, whatever the site adds next — never leaves the process. Values are checked rather than trusted: a control character anywhere in the header is refused outright, because a value carrying a newline is a header injection.

A value may also arrive **quoted**: Chrome quotes this platform's `serviceToken` on the wire, so the header pasted out of a network tab carries a matched pair of quotes around it — RFC 6265's own spelling of a cookie-value. One surrounding pair is stripped rather than refused — refusing it made the documented paste path reject the platform's own session — and the bare value is what is re-sent; the live route accepts it unquoted. A quote that is not wrapping the whole value, a backslash or a space is still a refusal.

A repeated name takes the first and is **not** an error. Every browser store routinely holds a host-only row and a domain row for one cookie, and the host match returns both; throwing there discarded the whole browser in silence. That lesson is Ollama's, written down in `OllamaSessionCookie.normalize` and repeated here because the shape of the mistake is the shape of this whole feature.

Safari's store needs Full Disk Access; the Chromium browsers ask for keychain permission once. Both are properties of reading a browser, not of this provider — [authentication.md](authentication.md).

## Routes

`GET https://platform.xiaomimimo.com/api/v1/…`, three of them, fetched together:

| Path | Carries |
|---|---|
| `tokenPlan/usage` | `data.monthUsage.items[]` — `used`, `limit` per bucket |
| `tokenPlan/detail` | `data.planName` (the name shown) falling back to `data.planCode`, plus `data.currentPeriodEnd`, `data.expired` |
| `balance` | `data.balance` and `data.currency`, as strings |

**The plan's failure is the call's failure; the balance's is the money.** The plan's ring comes from `tokenPlan/usage`, so a usage route that does not answer is an unavailable provider. The balance route carries everything money-shaped — `creditBalance`, the balance row, and the figure a "warn below" line compares — and nothing else depends on it, so losing it costs exactly those. On an account with **no plan** the balance *is* the whole reading, and losing it there leaves `.xiaomiNoCodingPlan`, which is why "nothing answered" throws rather than reporting that sentence. `tokenPlan/detail` is in between: it carries the reset and the plan's name, and without it the row still draws with neither.

`monthUsage.items` is a list because the console draws a row per bucket. The plan's own allowance is the first, and **a null or empty list is an account with no plan** — one that buys tokens by the yuan; a live no-plan account answers `items: null`, where `[]` was the guess, and the decoder takes either as the same state. That is a complete answer, not a fault: where the account has money the balance row is the whole reading, and only an account with neither plan nor balance comes back `.xiaomiNoCodingPlan`. Neither is ever drawn as 0%, which would read as a full month nobody has. `zaiNoCodingPlan` exists for exactly the same reason.

An `expired` plan keeps reporting last month's figures until it renews. Those are not a current allowance, so nothing is drawn.

## The envelope answers inside a 200

Every route returns `{ "code": …, "message": …, "data": … }` over **HTTP 200**, including when the session is refused: `code` 401 or 403 in the body with a 200 on the wire. So the body is read on every route, not just on the one that failed — read as a success, a refused session comes out as "no Coding Plan on this account", which sends somebody to look at their subscription instead of at their login. A refused session's actual body was captured on the live pass: `{"code":401,"loginUrl":…}` — the sign-in redirect handed back as data, on the same envelope.

This is the same shape that had Zhipu reporting "the service returned an error" for the commonest mistake there is; see [zai.md](zai.md).

**Every route's outcome is kept, not discarded.** The first version wrapped all three calls in `try?`, which made the whole status-code switch below unreachable: an HTTP 401, a 429 and a 500 all became three nils and came out as "the reply could not be read". Each route now returns a `Result`, and when none of them answers the most actionable failure wins — a refused session outranks a timeout, because that is the one with a remedy. A transport failure is `.unreachable`, not `.unreadableReply`; the second means something came back.

The envelope is checked on **both** plan routes as well as on the balance, for the same reason. Read without it, a `code` 500 carrying an empty `items` came out as `.xiaomiNoCodingPlan` — a server fault reported as a subscription, and one `UsageAlerts` would then treat as an answer that clears an outage.

On the wire, `3xx` and `401`/`403` are all read as an expired session — an expired login is answered by redirecting the API call at the sign-in flow, so a redirect here is a credential problem rather than a moved endpoint.

## What the rail is told

**Two windows, where there is money to draw.** `xiaomi.plan`, `kind: .monthly`, from the plan; `xiaomi.balance`, `kind: .balance`, from the prepaid balance. The plan's row comes first, and the headline rule takes it from there — the *fullest* window gets the ring, so a nearly-spent balance is allowed to outrank a barely-touched month because that is what will actually bite first. With the second-ring setting on, the two are simply the pair.

The plan's `windowSeconds` is thirty days and **`reportsLength` is false**. The platform states when the period ends and never how long it is, and a billing month is not a fixed number of seconds — so the length is a sort key, the window-clock arc is not drawn, and the forecast does not divide by it. Copilot's calendar month is carried the same way; see the `windowSeconds` section of [README.md](README.md).

The reading carries `creditBalance` (the exact money, formatted) and `creditRemaining` (amount + currency) alongside the windows, so Settings, `--json` and the alert rule always have the figure: the card shows the fractions, as DeepSeek's does, with the exact sum beside the balance's own percentage — the account pane's **Balance amount** row, on by default — and in Settings.

### The balance's denominator is a peak Pulse watched

The platform reports money and **no allowance** to take a percentage of — DeepSeek's hole, filled by DeepSeek's rule: the denominator is the highest balance Pulse has watched in this currency since it last rose, and a balance that goes *up* can only be a top-up, which resets the mark. It is a figure Pulse **watched**, not one it made up, and the row still says it was inferred — `estimate` is `.sinceTopUp`, so the card writes the name as "Balance · since top-up" and `--json` reports `estimated: true` with `estimatedFrom: "sinceTopUp"`, exactly as [deepseek.md](deepseek.md) lays out.

What it costs is the first run: with no mark yet, the first reading *becomes* the mark and the row reads 0% until money is actually spent. A peak of zero — an account that has never held credit — draws no row at all: never having had money is not the same as having spent it.

Marks live in `xiaomimimo-baseline.json` — **this provider's own file**, one mark per currency, written off the main thread on the shared serial queue. The scope is the point: `DeepSeekBaseline` takes one precisely so that two accounts priced in the same currency cannot borrow each other's peaks, and neither file needed migrating when the scope was added. The mark is advanced once per **successful** fetch, in `XiaomiMiMoUsageService.fetch()`, not inside `reading(from:peak:)` — which takes the peak it is to draw against, so the mapping stays pure and a test run never writes into the marks of whoever is running it.

There is **no basis picker** the way DeepSeek's pane has one: `sinceTopUp` is the only denominator this provider can offer, so nothing is asked and nothing beyond the warn-below row is added to its pane.

**Without a plan:** the balance window *is* the reading — a ring the rail draws like any other, rather than the plain-figure fallback that used to be the whole card. A balance of **zero** with no plan is neither window nor refusal: it keeps `creditBalance`, the card draws "Credit balance", and the rail draws the short money form — an account that has spent everything is not one Pulse failed to read. `.xiaomiNoCodingPlan` remains for a session that worked and an account with neither plan nor money.

`reportsSpendableBalance` is **true**: there is money to put a figure against, so the account pane grows the usual Notifications group with a "warn below" line, comparing `creditRemaining` against the figure the reader typed — money against money, never ¥ against $. The rule, its re-arming and why it is one per account: [../notifications.md](../notifications.md).

With the flag above goes its inverse, `spendingIsWatchedLocally` — false for this provider now. Credit draining on Xiaomi's servers is invisible to AdaptiveRefresh's local signals, so the wait is **capped at `unwatchedCeiling`** instead of sitting on the half-hour ceiling; the same treatment DeepSeek and Command Code get. [../refresh-and-data.md](../refresh-and-data.md)

## Measured live (2026-09-21)

One pass against the real platform, issuing exactly what `XiaomiMiMoClient` builds — the normalizer's four cookie names reassembled unquoted as `name=value`, GET, and only the four headers `get` sends: no `x-timezone`, no `accept-language`. No token, user id or account name from that session lives in this repository; the fixtures carry the **key sets** observed, with values kept neutral.

- All three routes answered **HTTP 200 with `code: 0`** — the envelope as written, and the header set above is sufficient.
- `balance` held seven fields: six string decimals — `balance`, `frozenBalance`, `overdraftLimit`, `remainingOverdraftLimit`, `giftBalance`, `cashBalance` — beside a `currency` code, and that code read **`CNY`**, the ISO spelling `NumberFormatter` needs for its symbol and the mark needs for a stable key.
- **`cashBalance` + `giftBalance` summed exactly to `balance`** — so `balance` is the total, and stays what the ring, the card's money and the warn-below line read.
- A refused session answered `{"code":401,"loginUrl":…}` inside the same envelope — the shape `refusal(in:)` reads, now pinned by the `xiaomi-signed-out` fixture.
- The no-plan shapes are live: `monthUsage.items` came back **null**, with every `tokenPlan/detail` field null except the auto-renew defaults — `xiaomi-no-plan.json` is that reply.

## Unconfirmed

Settled by the pass above and so gone from this list: the currency's spelling, what `balance` adds up to, and whether `planCode` was a name or an identifier — the detail route carries a `planName` beside it, and that is the one shown now, with `planCode` as the fallback.

- **Everything that needs an account with a running plan.** `monthUsage.items.first` is still taken as the plan's allowance, and on an account whose console shows several buckets the first may not be the one the plan is sold as. The same account is what would show what an active `planName` and `planCode` read as, whether `currentPeriodEnd` really carries the console's `yyyy-MM-dd HH:mm:ss` in UTC while a period is running, and whether a live item matches `xiaomi-plan-usage.json` — the one fixture that stays written to the contract, because no live reply has ever had a plan on it.
- **A top-up landing.** No live account has watched `balance` *rise* to confirm what `sinceTopUp` assumes: a rise is read as a top-up and resets the peak.

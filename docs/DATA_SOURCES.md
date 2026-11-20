# Data sources

**Rule:** every external call goes through a backend client with caching and a rate limiter. Each source must be checked against its current terms before it is used. Endpoints were checked live on **2026-11-15**. Facts are marked **verified** (seen in a live response or quoted from official docs) or **unverified** (expected, not yet seen). None of these endpoints has a formal contract, so re-check them before each league.

**All URLs live in one module**: `Quicksilver.Integrations.Urls` (backend, I1/I2). The poe.ninja move on 2026-11-15 (see below) is exactly the risk this table warned about. The next move should be a one-file change.

| Source | Used for | Auth | Notes / risks |
|---|---|---|---|
| **Official trade API** (`www.pathofexile.com/api/trade/search` + `/fetch`) | Pricing rares and anything poe.ninja doesn't cover | None (verified) | Not in GGG's developer API reference (see Compliance note). Search and fetch have **separate** rate-limit policies, announced in headers. |
| **Official trade static data** (`/api/trade/data/stats`, `items`, `static`) | Mapping parsed mods to stat IDs; base/unique names; currency ids for searches | None (verified) | Large responses. Cache per league and refresh daily. |
| **Trade league list** (`/api/trade/data/leagues`) | League selector (preferred) | None (verified) | Its ids are the ones the trade API expects. Filter `realm == "pc"`. |
| **Legacy league list** (`api.pathofexile.com/leagues`) | Fallback league selector | None (verified) | Undocumented legacy endpoint with its own limit policy. The documented `GET /league` needs OAuth (verified 401 without a token). |
| **poe.ninja** (`poe.ninja/poe1/api/...`) | Currency rates; prices for uniques, gems, cards, fragments, maps, bases | None (verified) | No formal contract. **Moved on or before 2026-11-15**: the old `/api/data/*` endpoints now return 404. Follow its `Cache-Control` header. |
| **Official developer API (OAuth)** | Stretch: reading the user's own stash tabs | OAuth app registered with GGG; approval is manual and can take time | Not needed for the MVP. The trade overlay uses Client.txt, not the API. |
| **Official Currency Exchange history** (`web.poecdn.com/api/currency-exchange`) | Possible later use: official currency volume/ratio history | None, per docs (unverified live) | Hourly historical digests only; the current hour can't be queried. Not used for live prices. |
| **poewiki.net** (Cargo queries) | Item base data, unique info | None | Optional enrichment. Not checked yet. |
| **Client.txt** (local file) | Trade whispers, zone changes, session tracking | n/a | Path depends on install. Auto-detect both the Steam and standalone default paths, with a user override in settings (decided 2026-11-15). |

## Rules for every client

### User-Agent
- GGG's developer docs (verified) say any application using their API must send an identifiable User-Agent with this prefix: `OAuth {clientId}/{version} (contact: {contact}) ...`.
- Until we have an OAuth client id, use `Quicksilver/{version} (contact: https://github.com/dxu13UW/Quicksilver)`. Once one is registered, switch to the `OAuth ...` form.
- The contact is the repo URL (decided 2026-11-15), so no personal email appears in requests.
- Send the same User-Agent to poe.ninja and every other host.

### Reading GGG rate-limit headers
These header semantics are verified from GGG's developer docs and match the live responses.

| Header | Meaning |
|---|---|
| `X-Rate-Limit-Policy` | Name of the policy for this request. Key the limiter on this name, not on the URL. |
| `X-Rate-Limit-Rules` | Comma-separated rule names, e.g. `Ip` (an `Account` rule is possible when authenticated; unverified). |
| `X-Rate-Limit-{Rule}` | Comma-separated tiers, each `max hits : period s : restriction s` (the lockout if the tier is broken). |
| `X-Rate-Limit-{Rule}-State` | Same tiers, each `current hits : period s : active restriction s` (0 = not restricted). |
| `Retry-After` (on 429) | Seconds to wait before the restriction ends. Verified in the docs; not seen live (we never hit a 429). |

Client behaviour:
- **Cold start:** until a policy's headers have been seen, allow one request in flight for that policy.
- **Before each request,** check every tier of every rule. If sending would take the hits in `period` above `max hits`, **queue** the request until the oldest relevant hit leaves the window (plus a 500 ms safety margin for clock and network skew). Never drop the request. The state header gives a count but no window start, so keep our own timestamps per policy and resync them from `-State` on each response (if the server counts more hits than we do, add the difference as hits at "now").
- **A 429 with no rate-limit headers at all** (e.g. from a CDN): pause that endpoint family for `Retry-After`, or 60 s if that is missing too. This is a back-off, not a rate.
- **Update on every response.** GGG says limits are dynamic and can change at any time.
- **On 429:** pause the whole policy for `Retry-After` seconds, or for the active restriction in `-State` if that is larger. Don't retry sooner. GGG warns that frequent violations can get access revoked.
- **Example only, observed 2026-11-15. Never use these as constants:**
  - search (`trade-search-request-limit`): `x-rate-limit-ip: 5:10:60,15:60:300,30:300:1800,600:21600:3600`
  - fetch (`trade-fetch-request-limit`): `x-rate-limit-ip: 12:4:10,16:12:300,50:300:300,1000:21600:1800`
  - legacy leagues (`ladder-view`): `x-rate-limit-ip: 5:5:10,10:10:30,15:10:300`
- The trade `data/*` endpoints returned **no** rate-limit headers (verified), only `cache-control: public, max-age=…`. Still send them through the same client, with one request in flight.
- poe.ninja sends **no** rate-limit headers either (verified 2026-11-19). Same treatment: one request in flight.

### Implementation (I1/I2, 2026-11-19)
- Client: `Quicksilver.Integrations.HTTP.get_json/2` over `mint` (one connection per request, HTTP/1.1). TLS uses `verify: :verify_peer` with OTP's `:public_key.cacerts_get()`. Verified from Erlang/OTP 27.2 against both www.pathofexile.com and poe.ninja.
- Sends `accept-encoding: gzip`; both hosts answer with gzip (verified). With `br` offered (curl), poe.ninja answers in brotli, which we don't decode, so we never offer it.
- Limiter: `Quicksilver.Integrations.RateLimiter`, keyed by endpoint family (bucket); a bucket maps to the policy named in `X-Rate-Limit-Policy` once seen.
- Week 2 keeps two poe.ninja overviews fresh for the current league only: `Currency` (exchange; feeds `rates.update`) and `UniqueAccessory` (stash). The list is configurable (`Quicksilver.Integrations.Config`).
- Tests replay recorded responses (`backend/test/fixtures/integrations/`, some trimmed) through a fixture adapter. In the test env the real adapter is replaced by one that refuses all requests. `QUICKSILVER_OFFLINE=1` does the same for a dev run.

### Compliance note (owner decision needed)
GGG's developer docs (verified) say: "We can only support resources defined in our API Reference," and that reverse-engineering endpoints outside that documentation is against the Terms of Use (section 7i). The trade endpoints, the trade data endpoints and the legacy `/leagues` are **not** in that reference. Community tools use them widely, but this is a risk for the project.
**Decided 2026-11-15 (ADR-004):** the risk is accepted. The trade API is used only for items poe.ninja can't price, only on demand, and behind the `trade_api_enabled` kill switch. Recorded in COMPLIANCE.md.

## Endpoints (verified 2026-11-15)

### poe.ninja
- **Gone (verified 404):** `/api/data/currencyoverview`, `/api/data/itemoverview`.
- `GET /poe1/api/data/index-state` (verified)
  - Keys: `economyLeagues`, `oldEconomyLeagues`, `buildLeagues`, `oldBuildLeagues`. **`snapshotVersions` was gone on 2026-11-19** (present on 11-15).
  - Each `economyLeagues` entry is `{name, url, displayName, isPrivate}`. Live: Covens, Hardcore Covens, Standard, Hardcore.
  - `cache-control: public, max-age=300, …`. This differs from the overview endpoints.
- `GET /poe1/api/economy/exchange/current/overview?league={name}&type={type}` (verified)
  - Top-level keys: `core`, `lines`, `items`.
  - `core = {items, rates, primary: "chaos", secondary: "divine"}`. `rates.divine` is divines per chaos (0.006861 live, so 1 div ≈ 145.7 c; 0.004626 = 216.2 c on 2026-11-19). Chaos per divine = `1 / rates.divine`.
  - `lines` **includes a `divine` line** (`primaryValue` 216.2 on 2026-11-19, matching `1 / rates.divine` to 0.1 c) and a `chaos` line (`primaryValue` 1). We take `divine_chaos` from the `divine` line, falling back to `1 / rates.divine`.
  - Every `lines` entry had a matching `items` entry, and every one had a `sparkline` (106 lines, 2026-11-19).
  - Each `lines[]` entry is `{id, primaryValue (chaos), volumePrimaryValue, maxVolumeCurrency, maxVolumeRate, sparkline{totalChange, data}}`.
  - Each `items[]` entry is `{id, name, image, category, detailsId}`. Join it to `lines` on `id`.
  - **Working types (verified, non-empty):** `Currency` (105), `Fragment` (66), `DivinationCard` (367), `Essence` (105), `Fossil` (25), `Oil` (16).
  - **An unknown type returns 200 with empty `lines`** (verified with a bogus type), and so did `Scarab`. Treat empty `lines` as "type not supported", never as "no prices". The scarab type name is unverified.
  - Other likely types (Resonator, Incubator, DeliriumOrb, Omen, Tattoo, …) are unverified.
- `GET /poe1/api/economy/stash/current/item/overview?league={name}&type={type}` (verified)
  - Shape: `{lines:[…]}`. `UniqueAccessory` had 363 lines on 2026-11-19; `divineValue` was **missing** on 110 of them (only `chaosValue` is always there). Line fields include `id, name, baseType, itemClass, icon, chaosValue, divineValue, exaltedValue, listingCount, count, detailsId, sparkLine, implicitModifiers, explicitModifiers`. Some types add more: `links` (weapons), `variant`, `mutatedModifiers`, `tradeInfo`, `gemLevel` and `corrupted` (gems).
  - **Working types (verified, non-empty):** `UniqueWeapon`, `UniqueArmour`, `UniqueAccessory`, `UniqueFlask`, `UniqueJewel`, `UniqueMap`, `SkillGem` (5,689 lines), `Map`, `BaseType` (12,377 lines, large), `ClusterJewel`.
  - **Not here (verified):** `DivinationCard` returns 404, and `Fragment` returns 200 with empty `lines` (`no-cache`). Both now live on the exchange endpoint. An unknown type returns 404.
  - Other types (UniqueRelic, Beast, Invitation, Memory, …) are unverified.
- **Headers (verified):** successful overviews send `cache-control: public, max-age=1800, stale-while-revalidate=300, stale-if-error=86400` and a weak `etag`.
  - poe.ninja is behind Cloudflare and sends an **`Age`** header (e.g. 253, 789, 1331 s on 2026-11-19), so the remaining freshness is `max-age - Age`, not `max-age`.
  - Exception: `Essence` (exchange) sent `cache-control: no-cache` on two requests, even though the data looked complete.
  - 404s are also sent `no-cache`.
  - Conditional requests (`If-None-Match`) are unverified.

### Official trade API (`https://www.pathofexile.com`)
- `POST /api/trade/search/{league}` (verified, no auth)
  - Example body: `{"query":{"status":{"option":"online"},"name":"Tabula Rasa","type":"Simple Robe"},"sort":{"price":"asc"}}`.
  - Response: `{id, complexity, result:[listing ids], total}`. `complexity` was not in earlier notes; it was `4` live.
  - Policy: `trade-search-request-limit`.
- `GET /api/trade/fetch/{ids}?query={searchId}` (verified with 10 ids)
  - Response: `{result:[{id, listing, item}]}`.
  - `listing` has `price {type, amount, currency}` (e.g. `~b/o`, 3, `chaos`), `account`, `stash`, `whisper`, `indexed`, `method`, `in_demand`.
  - `item` has `name, typeLine, baseType, ilvl, rarity, sockets, league, extended, …`.
  - Policy: `trade-fetch-request-limit`, separate from search.
  - The 10-id maximum per fetch is unverified; we didn't test 11.
- `whisper` is ready-made chat text. Sending it is a game action: at most one per keypress (COMPLIANCE.md).

### Official trade static data (`https://www.pathofexile.com/api/trade/data/…`)
- All three answered with `cache-control: public, max-age=300` and a `last-modified` header (verified). `If-Modified-Since` support is unverified.
- `GET /stats` (verified)
  - `result` is a list of groups `{id, label, entries}`: Pseudo, Explicit, Implicit, Imbued, Fractured, Enchant, Scourge, Crafted, Mercenary, Veiled, Delve, Ultimatum, Sanctum, Crucible.
  - 18,636 entries live (vs 18,635 in earlier notes; the count drifts).
  - Example entry: `{"id":"pseudo.pseudo_total_cold_resistance","text":"+#% total to Cold Resistance","type":"pseudo"}`.
- `GET /items` (verified)
  - `result` has 23 groups `{id, label, entries}` (accessory, armour, card, currency, gem, map, weapon, …), 6,237 entries in total.
  - Each entry is `{type}` for a base, or `{type, text, name, flags:{unique:true}}` for a unique.
- `GET /static` (verified)
  - `result` has 21 groups (Currency, Fragments, Essences, Cards, Oils, Catalysts, Delve, …).
  - Each entry is `{id, text, image}`, e.g. `{"id":"alt","text":"Orb of Alteration"}`. These ids are the currency codes used in searches.

### League list
- `GET https://www.pathofexile.com/api/trade/data/leagues` (verified, **preferred**)
  - Response: `result:[{id, realm, text}]` with realm `pc` / `xbox` / `sony`.
  - PC has 8 leagues: Covens, Hardcore Covens, Ruthless Covens, HC Ruthless Covens, Standard, Hardcore, Ruthless, Hardcore Ruthless. No SSF leagues, since SSF can't trade.
  - `cache-control: public, max-age=120`. On 2026-11-19 it also came with `Age: 1534`, i.e. Cloudflare served a copy older than its `max-age` (with `expires` and `last-modified` headers). The list was still correct, and our TTL is fixed at 1 h, so this doesn't matter for us.
- `GET https://api.pathofexile.com/leagues?type=main` (verified, fallback)
  - Response: a bare list of 16 entries `{id, realm, name, url, category, description, rules, registerAt, startAt, endAt, delveEvent}`. It includes SSF leagues.
  - Policy: `ladder-view`.
- `GET https://api.pathofexile.com/league` (the documented endpoint) returned **401** without a token (verified). It needs the `service:leagues` scope.
- The current challenge league is **Covens** (verified).

## Caching policy
Every cache has an explicit TTL (NFR-API-3). "Header" means the response's `Cache-Control: max-age`. We never refetch before the TTL expires. A longer TTL than the header's is allowed.

| Cache | Key | TTL | Notes |
|---|---|---|---|
| poe.ninja exchange overview | league + type | Header `max-age` minus `Age` (1800 s seen, minus CDN age). **Fallback 30 min** if the header is missing, `no-cache` or 0. Never below 60 s. | On fetch error, serve stale data for up to `stale-if-error` (86,400 s seen; fallback 24 h) and mark it stale in the UI. Retries back off 60 s, doubling, max 30 min. In memory. |
| poe.ninja stash item overview | league + type | Same as the exchange overview. | Same as the exchange overview. |
| poe.ninja index-state | none | 1 h (header said 300 s) | Consulted before fetching a league's overviews; leagues it doesn't list (e.g. Ruthless) are never requested. In memory. |
| Trade league list | none | 1 h (header said 120 s); refresh at startup | Leagues change only at launch or end. On fetch error the last list is served for the rest of the run; retries back off 60 s, doubling, max 1 h. In memory (not on disk yet, so an offline start has no list and falls back to `Standard` or the saved league). |
| Legacy league list | none | 1 h | Fallback only. |
| Trade static data (stats, items, static) | endpoint | 24 h; refresh at startup and on league change | Keep the last good copy on disk. |
| Trade search result | league + normalized query JSON | 5 min | Fetched listings are cached with it. |
| Trade fetch (listings) | listing id | 5 min | Same lifetime as the search that produced it. |
| poewiki Cargo | query | 7 days (provisional; source not checked) | Optional. |
| Client.txt | n/a | Not cached; tailed live | Local file. |

## Behaviour changes log
- **2026-11-15:** poe.ninja moved its PoE 1 API from `/api/data/*` (now 404) to `/poe1/api/data/index-state`, `/poe1/api/economy/exchange/current/overview` and `/poe1/api/economy/stash/current/item/overview`. Divination cards and fragments moved from the item overview to the exchange endpoint.
- **2026-11-19:** poe.ninja `index-state` no longer has a `snapshotVersions` key. Live responses from poe.ninja and the trade league list carry a Cloudflare `Age` header (the trade league list once with `Age` > `max-age`). Neither host sends rate-limit headers on the endpoints used by I1/I2. The exchange overview has a `divine` line. Recorded fixtures: `backend/test/fixtures/integrations/`.

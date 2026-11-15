# Data sources

**Rule:** every external call goes through a backend client with caching and a rate limiter. Each source must be checked against its current terms before it is used. Endpoint details below are a starting point **to verify in Week 2**; none are guaranteed.

| Source | Used for | Auth | Notes / risks |
|---|---|---|---|
| **Official trade API** (pathofexile.com trade search + fetch) | Pricing rares and anything poe.ninja doesn't cover | None for public search | Strict rate limits announced in response headers; policies can change, so read headers and never hardcode. Requires a descriptive User-Agent with contact info. |
| **Official trade static data** (items, stats, static) | Mapping parsed mods to stat IDs for searches | None | Cache aggressively; refresh per league. |
| **Official league list** | League selector | None / OAuth depending on endpoint | Verify which endpoint is public. |
| **Official developer API (OAuth)** | Stretch: reading the user's own stash tabs | OAuth app registered with GGG; approval is manual and can take time | Not needed for the MVP. The trade overlay uses Client.txt, not the API. |
| **poe.ninja** | Currency rates; prices for uniques, gems, fragments, etc. | None | No formal published API contract; endpoints may change. Cache and refresh on a schedule, and be polite. |
| **poewiki.net** (Cargo queries) | Item base data, unique info | None | Optional enrichment. |
| **Client.txt** (local file) | Trade whispers, zone changes, session tracking | n/a | Path depends on install. Auto-detect both the Steam and standalone default paths, with a user override in settings (decided 2026-11-15). |

## Caching policy (draft)
- **Currency rates:** refresh every 15–30 min.
- **Item overviews:** refresh every 30–60 min.
- **Static trade data:** refresh at startup and daily.
- **Trade search results:** cache for a few minutes per identical query.

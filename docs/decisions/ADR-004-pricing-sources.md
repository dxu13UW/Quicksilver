# ADR-004: Split pricing between poe.ninja and the trade API
**Status:** Accepted (2026-11-15)

**Context**
- poe.ninja prices common items well, and it isn't run by GGG. It can't price rares, whose value depends on their random mods.
- The official trade API can price anything. However, GGG's developer docs (checked 2026-11-15) say that only endpoints in their API Reference are supported, and that reverse-engineering other endpoints is against the Terms of Use (section 7i).
  - The trade search and fetch endpoints are not in that reference.
  - Desktop apps are told to use a registered public OAuth client, and GGG currently isn't accepting new registrations.
- Popular community tools use the trade API daily. Searches without a login aren't tied to an account, so the practical risk is temporary IP lockouts, or GGG changing or blocking the endpoints, not account bans. Details are in DATA_SOURCES.md.

**Decision**
Use **both** sources, split by item type. **poe.ninja first; the trade API only for what poe.ninja can't price.**

| Item | Source |
|---|---|
| Currency, fragments, divination cards, essences, fossils, oils (and other exchange types once verified) | poe.ninja exchange overview |
| Uniques, skill gems, maps, cluster jewels, bases | poe.ninja stash item overview |
| Rares, magic items, and anything poe.ninja has no match for | Trade API (one search + one fetch of up to 10 listings) |
| poe.ninja match with very few listings (threshold to tune in Week 3) | poe.ninja estimate shown as low confidence. The trade API runs **only if the user asks for it** (e.g. a "check live listings" button). |

Safeguards for the trade API:
- **On demand only.** A trade API request happens only after a user's price-check keypress or click. No background polling, no prefetching, and no automatic retries after errors.
- **Rate limits from headers, with queuing** (DATA_SOURCES.md). The target is zero 429s (NFR-API-1).
- **Kill switch.** A config setting `trade_api_enabled` (default `true`). When it is off, rares show an **"Open on trade site"** link in the browser instead of an in-app price. The same fallback appears while the trade API is unreachable or locked out.
- **League list.** Use the trade league list (one cached request per hour). Its ids are exactly the names the trade API expects.
- Every request carries the project User-Agent with a contact address, as GGG asks.

**Consequences**
- Rares are priced in-app for v0.1 (REQUIREMENTS PC-4 becomes a Must), which keeps Week 3 as planned.
- The risk is accepted and recorded in COMPLIANCE.md. If GGG blocks or changes the endpoints, flipping the kill switch keeps everything except in-app rare pricing working.
- Revisit this ADR if GGG opens app registration again, or adds trade search to its documented API.

**Rejected**
- **poe.ninja only:** no in-app price for rares, which are the items players most need help pricing.
- **Trade API for everything:** much more traffic against undocumented endpoints, for items poe.ninja already prices well.

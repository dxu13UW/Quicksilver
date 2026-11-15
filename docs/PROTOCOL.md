# Protocol (draft v0)

The only interface between the C++ client and the Elixir backend.
- **Transport:** WebSocket at `ws://127.0.0.1:<port>/ws`. Port is chosen by the backend and passed to the client at launch. Text frames carry JSON.
- **Change rule:** edit this file first, bump `protocol_version`, then update both sides. QA checks both against this file.

## Envelope
Every message has the same outer shape:
- `type`: message name, e.g. `price.request`
- `id`: request id chosen by the sender. Replies echo it; server pushes have `null`.
- `ts`: ISO-8601 timestamp
- `payload`: object, specific to the type

## Messages (initial set)

### Connection
| Type | Direction | Purpose |
|---|---|---|
| `hello` | client → server | Client version, protocol_version |
| `welcome` | server → client | Server version, league, feature flags |
| `health` | server → client (push, every N s) | Status of each external source, cache ages, rate-limit state |
| `error` | either | Code, human message, related `id` |

### Dashboard
| Type | Direction | Purpose |
|---|---|---|
| `leagues.list` / `leagues.result` | c→s / s→c | Available leagues |
| `league.set` | c→s | Change active league |
| `rates.subscribe` | c→s | Start receiving currency rates |
| `rates.update` | s→c (push) | Currency rate table snapshot |

### Price check
| Type | Direction | Purpose |
|---|---|---|
| `price.request` | c→s | Raw clipboard item text |
| `price.result` | s→c | Parsed item summary, estimate (low/median/high in chaos and divines), source, confidence, listing count |
| `price.pending` | s→c | Sent when a trade API request is queued behind a rate limit |

### Trade overlay
| Type | Direction | Purpose |
|---|---|---|
| `trade.incoming` | s→c (push) | Buyer, item, price, stash tab name, left/top position, league |
| `trade.dismiss` | c→s | User closed a request |

### Session (later)
| Type | Direction | Purpose |
|---|---|---|
| `session.update` | s→c (push) | Current zone, time in zone, maps run today |

## Open points
- Error code list
- Whether quick-reply text is built by the client or the server. Either way, the **user** presses the key that sends it (one action per keypress).

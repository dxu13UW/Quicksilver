# ADR-002: Local WebSocket between client and backend
**Status:** Accepted (Week 1)

**Decision**
The backend listens on 127.0.0.1 only, on a launch-time port, and exchanges JSON messages per PROTOCOL.md.

**Implementation (decided 2026-11-15)**
- A single Mix application, not an umbrella. Lanes are kept apart by module namespaces and supervision subtrees.
- **Bandit + WebSock** for the server. No Phoenix and no Channels.
  - This has the least overhead: one lightweight process per connection, raw text frames, and our own JSON envelope from PROTOCOL.md.
  - Phoenix Channels would add an endpoint/router, PubSub, and a `join`/`topic`/`ref` wire format that the Qt client would have to implement.

**Why**
- The connection is bidirectional, so the backend can push trades, rates, and health.
- It is easy to debug with any WebSocket tool.
- Both stacks have mature libraries.

**Rejected**
- **HTTP polling:** no push.
- **Named pipes:** harder to debug.
- **Embedding the BEAM in C++:** too complex.
- **Phoenix Channels:** extra wire format and layers we don't need for one local client.
- **Umbrella app:** more setup for a 4-week solo project, with no runtime benefit.

**Security note**
- Bind to localhost only.
- Consider a random per-launch token in `hello` so other local programs can't connect.

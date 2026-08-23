# Prototype architecture

Computer History is designed as two local processes with a narrow trust boundary.

```text
┌────────────────────────────────────────────────────────────┐
│ Computer History.app (Swift)                               │
│                                                            │
│ SwiftUI and AppKit                                         │
│        │                                                   │
│ macOS Accessibility → privacy policy → observations        │
│                                      │                     │
│                          episodes and approved memory       │
│                                      │                     │
│                         encrypted SQLite with FTS5          │
│                                      │                     │
│                  authenticated API on 127.0.0.1:47831       │
└──────────────────────────────────────┬─────────────────────┘
                                       │
                              versioned local JSON
                                       │
┌──────────────────────────────────────▼─────────────────────┐
│ TypeScript MCP adapter                                     │
│ validation → authenticated forwarding → result budgeting   │
│                                                            │
│ stdio MCP only; no database access and no persistent state │
└──────────────┬──────────────────┬──────────────────┬────────┘
               ▼                  ▼                  ▼
             Codex              Claude             Cursor
```

## Trust boundaries

- The Swift application is the only authority allowed to persist or mutate memory.
- The HTTP service binds only to loopback and requires a separate credential for each agent client.
- The MCP adapter stores nothing and reserves standard output exclusively for MCP messages.
- Captured text is untrusted evidence and must never be interpreted as a command by the memory service.
- Browser capture requires both an allowed browser application and an allowed domain.

## Memory layers

1. **Observation:** a sanitized, deduplicated Accessibility event.
2. **Episode:** a deterministic group of related observations.
3. **Durable memory:** a user-pinned item or user-approved agent proposal.
4. **Retrieval context:** temporary, size-budgeted evidence returned to an authorized agent.

## Implementation milestones

### 1. Application shell

Native SwiftUI dashboard, menu-bar controls, and visible capture state.

### 2. Private capture

Accessibility onboarding, empty initial allowlist, secure-field rejection, Chrome-domain rules, debouncing, and a live sanitized-event inspector.

### 3. Local memory

Keychain-managed database encryption, SQLite/FTS5, retention, deterministic episode grouping, correction, and deletion.

### 4. Agent access

Authenticated versioned loopback API, per-client audit records, TypeScript stdio MCP adapter, and agent integration templates.

### 5. Dogfood validation

Verify that multiple agents can answer where the user left off with the same episode, timestamps, applications, documents, and evidence identifiers.


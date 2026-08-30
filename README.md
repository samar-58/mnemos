# Mnemos

Mnemos is an open-source, local-first memory layer for AI agents on macOS.

The long-term goal is simple: your computer context should belong to you, and authorized agents such as Codex, Claude, and Cursor should be able to retrieve the same useful, provenance-backed memory.

> [!IMPORTANT]
> This repository is a dogfood prototype. Mnemos captures a privacy-filtered semantic event stream from explicitly allowed applications, derives sessions/tasks/spans/workstreams, and provides evidence-backed hybrid retrieval to local agents.

## Product principles

- **Local first:** captured history and derived memory remain on the Mac.
- **User owned:** memory is independent of any single agent vendor.
- **Private by default:** capture starts with an empty application and domain allowlist.
- **Evidence backed:** agents receive observations and episode IDs, not unsupported claims.
- **Untrusted input:** captured content is always treated as evidence, never as instructions.
- **Semantic capture:** meaningful app, window, input-target, and Accessibility-tree changes instead of screenshots, OCR, audio, or clipboard collection.

## Architecture

```text
Swift macOS app
├── Native UI and permissions
├── Accessibility collector
├── Privacy filtering
├── Private local SQLite / FTS5 storage
├── Workstream → session → task → span context engine
├── NLEmbedding + Accelerate exact semantic search
└── Authenticated loopback API
          ▲
          │ HTTP on 127.0.0.1
          │
TypeScript MCP adapter
          │ stdio MCP
    ┌─────┼─────┐
    ▼     ▼     ▼
 Codex  Claude Cursor
```

Swift owns collection, privacy policy, persistence, and product behavior. The TypeScript process is a stateless stdio MCP adapter; it never opens the database directly.

## Current status

The V3 evidence-backed memory and skill prototype is implemented:

- Swift 6 and SwiftUI macOS application
- Menu-bar app experience
- Native dashboard shell
- Overview, activity, permissions, agents, and settings sections
- Native Accessibility permission onboarding
- Empty-by-default application allowlist
- Event-driven AX notifications for application, window, focus, selection, and value changes
- Semantic buffered keyboard text/shortcuts and mouse click/drag targets
- Bounded initial Accessibility-tree snapshots followed by meaningful diffs
- Document/project paths and terminal output changes when allowed applications expose them
- Browser URL/content capture behind independent domain allowlisting
- Private-window, secure-input, password-field, disallowed-app, and disallowed-domain rejection
- Rolling duplicate suppression and common credential-pattern redaction
- Swift-owned SQLite persistence with schema migrations and private filesystem permissions
- Explicit workstreams and anchors across sessions, with session-owned task episodes and application spans
- Bounded task-candidate segmentation, interruption resumption, and background semantic reconciliation
- Versioned ingress and compact-evidence redaction, restricted custom rules, and category-only metrics
- Diverse compact evidence capped at 24 items per task
- Configurable 7/30/90-day or forever raw-observation retention; compact task memory remains separately
- Hybrid FTS5 plus Apple sentence-embedding retrieval with filtered candidates, exact Accelerate cosine scoring, and reciprocal-rank fusion
- Dynamic embedding dimensions stored with provider, language, revision, and content hash
- In-app hierarchical Memory inspector with filters, grouping explanations, provenance, rename/pin/workstream/merge/split/move/delete corrections
- Off-by-default, read-only agent access over an authenticated IPv4 loopback API
- Per-launch 256-bit bearer tokens handed to adapters through a user-only configuration file
- Deterministic and optional Codex App Server-enriched memory versions with nullable provenance, source coverage, and durable derivation jobs
- Evidence-backed workflow traces and repeated-pattern mining, consolidated into a single working-style skill describing the real toolchain, projects, order of work, and rhythm — with approval/rejection, version history, rollback, retirement, and optional native export
- Per-agent, revocable grant tokens with separate memories, approved-skills, and raw-evidence capabilities
- TypeScript stdio MCP adapter with ten tools for memory, timeline, task evidence, current/project state, and approved skills
- Local-calendar recall handling for latest work, last night, first meaningful activity after wake, and specific-day summaries
- In-app processing and integration health for Codex, the local API, MCP activity, grants, approved skills, job failures, and retries
- Structured MCP results, read-only annotations, provenance IDs, and explicit prompt-injection boundaries
- Additive, resumable V1-to-V2 observation replay with assignment, foreign-key, FTS, and vector validation
- Swift privacy/vector tests and live Swift-API/MCP integration smoke tests
- Reproducible Xcode project generation

The prototype database lives in `~/Library/Application Support/Mnemos/mnemos.sqlite`. It is restricted to the current macOS user and benefits from macOS/FileVault protection when FileVault is enabled. Application-level database encryption is not implemented yet and is required before a public alpha.

When local agent access is enabled in Mnemos, the app listens only on `127.0.0.1:17373` and writes a short-lived built-in connection configuration to `~/Library/Application Support/Mnemos/agent-api.json`. The file is mode `600`, its token rotates whenever the server starts, and the API is read-only. Separate named grants can be issued for individual agents and revoked immediately. The MCP adapter reloads its configured grant file for every tool call and never opens SQLite.

## Requirements

- macOS 15 or later
- Xcode 26 or later
- Node.js 20 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

Install XcodeGen with Homebrew:

```sh
brew install xcodegen
```

## Build and run

Clone the repository, then run:

```sh
make project
make build
make test
make run
```

Or open the generated project in Xcode:

```sh
make open
```

The generated `macos/Mnemos.xcodeproj` is intentionally ignored. [`project.yml`](project.yml) is the source of truth, which avoids noisy Xcode project-file conflicts.

Build and verify the MCP adapter:

```sh
cd mcp
npm ci
npm run build
npm test
npm run smoke
```

Register the compiled adapter with local hosts:

```sh
MNEMOS_NODE_BIN="$(command -v node)"
MNEMOS_ADAPTER="$(pwd)/build/index.js"
codex mcp add mnemos -- "$MNEMOS_NODE_BIN" "$MNEMOS_ADAPTER"
claude mcp add --scope user --transport stdio mnemos -- "$MNEMOS_NODE_BIN" "$MNEMOS_ADAPTER"
cursor --add-mcp "{\"name\":\"mnemos\",\"command\":\"$MNEMOS_NODE_BIN\",\"args\":[\"$MNEMOS_ADAPTER\"]}"
```

Restart the host after registration, then enable **Agents → Local agent access** in Mnemos. Registration alone does not grant memory access.

## Repository structure

```text
mnemos/
├── macos/Mnemos/            # SwiftUI application source
├── mcp/                     # TypeScript stdio MCP adapter
├── project.yml              # XcodeGen project definition
└── Makefile                 # Local development commands
```

## Milestones

1. Native macOS shell and menu-bar experience — complete
2. Accessibility onboarding and semantic event-stream capture — complete for the in-memory prototype
3. Local storage, deterministic episodes, and FTS5 retrieval — complete for the prototype
4. Authenticated loopback API — complete for the prototype
5. TypeScript stdio MCP adapter — complete for the prototype
6. Codex, Claude, and Cursor dogfood integration — configured locally
7. V2 hierarchical context engine, hybrid retrieval, and corrections — complete for dogfood
8. V3 evidence-backed memories, patterns, approved skills, ten-tool MCP, and per-agent grants — complete for dogfood

The prototype deliberately excludes cloud sync, screenshots, OCR, audio, clipboard capture, and autonomous actions. Optional Codex enrichment is off by default, runs through an isolated Codex App Server runtime, and sends only explicitly consented, previewable sources. Keyboard text is buffered into semantic chunks rather than persisted as individual key-down records, and secure input is always suppressed. Application-level database encryption, signing/notarization, update delivery, and public release operations remain blockers for public alpha.

## License

Mnemos is available under the [MIT License](LICENSE).

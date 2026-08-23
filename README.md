# Mnemos

Mnemos is an open-source, local-first memory layer for AI agents on macOS.

The long-term goal is simple: your computer context should belong to you, and authorized agents such as Codex, Claude, and Cursor should be able to retrieve the same useful, provenance-backed memory.

> [!IMPORTANT]
> This repository is an early prototype. The current milestone provides the native macOS application shell and menu-bar experience. It does **not** capture or store computer activity yet.

## Product principles

- **Local first:** captured history and derived memory remain on the Mac.
- **User owned:** memory is independent of any single agent vendor.
- **Private by default:** capture starts with an empty application and domain allowlist.
- **Evidence backed:** agents receive observations and episode IDs, not unsupported claims.
- **Untrusted input:** captured content is always treated as evidence, never as instructions.
- **Minimal capture:** no raw keystrokes, screenshots, OCR, audio, or clipboard collection.

## Architecture

```text
Swift macOS app
├── Native UI and permissions
├── Accessibility collector
├── Privacy filtering
├── Encrypted SQLite / FTS5 storage
├── Episode and memory engine
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

Swift will own collection, privacy policy, persistence, and product behavior. The future TypeScript process will be a stateless stdio MCP adapter; it will never open the database directly.

## Current status

Milestone 1 is implemented:

- Swift 6 and SwiftUI macOS application
- Menu-bar app experience
- Native dashboard shell
- Overview, activity, permissions, agents, and settings sections
- Reproducible Xcode project generation

The capture toggle currently changes UI state only. No activity is recorded.

## Requirements

- macOS 15 or later
- Xcode 26 or later
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
make run
```

Or open the generated project in Xcode:

```sh
make open
```

The generated `macos/Mnemos.xcodeproj` is intentionally ignored. [`project.yml`](project.yml) is the source of truth, which avoids noisy Xcode project-file conflicts.

## Repository structure

```text
mnemos/
├── macos/Mnemos/            # SwiftUI application source
├── docs/                    # Product and architecture notes
├── project.yml              # XcodeGen project definition
└── Makefile                 # Local development commands
```

## Roadmap

1. Native macOS shell and menu-bar experience — complete
2. Accessibility onboarding and allowlist-only capture
3. Privacy filtering, encrypted storage, and deterministic episodes
4. Authenticated loopback API
5. TypeScript stdio MCP adapter
6. Codex, Claude, and Cursor dogfood integration

The prototype deliberately excludes cloud sync, screenshots, OCR, audio, clipboard capture, internal LLM calls, and embeddings.

## License

Mnemos is available under the [MIT License](LICENSE).

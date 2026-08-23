# Mnemos MCP adapter

This package is the stateless stdio bridge between MCP hosts and the Swift-owned Mnemos memory service. It never opens SQLite.

## Tools

- `search_memory` — ranked retrieval across episodes and supporting observations
- `recent_activity` — recent persistent episodes
- `get_episode` — one episode by ID
- `get_evidence` — provenance observations for an episode

All tools are read-only and mark captured computer content as untrusted evidence rather than instructions.

## Build

```sh
npm install
npm run build
npm run smoke
```

Mnemos must be running with **Agents → Local agent access** enabled before retrieval calls will succeed. The adapter reloads `~/Library/Application Support/Mnemos/agent-api.json` for every call, validates its ownership and permissions, and accepts only an IPv4 loopback endpoint.

To include real Swift API retrieval in the smoke test after enabling access:

```sh
MNEMOS_EXPECT_API=1 npm run smoke
```

MCP hosts should launch the compiled adapter with Node:

```text
node /absolute/path/to/mnemos/mcp/build/index.js
```

Register it with Codex and Claude Code from this directory:

```sh
MNEMOS_NODE_BIN="$(command -v node)"
MNEMOS_ADAPTER="$(pwd)/build/index.js"
codex mcp add mnemos -- "$MNEMOS_NODE_BIN" "$MNEMOS_ADAPTER"
claude mcp add --scope user --transport stdio mnemos -- "$MNEMOS_NODE_BIN" "$MNEMOS_ADAPTER"
cursor --add-mcp "{\"name\":\"mnemos\",\"command\":\"$MNEMOS_NODE_BIN\",\"args\":[\"$MNEMOS_ADAPTER\"]}"
```

Restart the MCP host after registration. The tools remain unable to retrieve memory until the user enables local agent access inside Mnemos.

import assert from "node:assert/strict";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";

const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [resolve(packageRoot, "build", "index.js")],
  stderr: "pipe",
});
const client = new Client({ name: "mnemos-smoke-test", version: "0.1.0" });

try {
  await client.connect(transport);
  const listed = await client.listTools();
  const names = listed.tools.map((tool) => tool.name).sort();
  assert.deepEqual(names, ["get_episode", "get_evidence", "recent_activity", "search_memory"]);
  assert.ok(listed.tools.every((tool) => tool.annotations?.readOnlyHint === true));

  if (process.env.MNEMOS_EXPECT_API === "1") {
    const recent = await client.callTool({ name: "recent_activity", arguments: { limit: 2 } });
    assert.notEqual(recent.isError, true, "recent_activity should reach the Swift API");
    const episodes = recent.structuredContent?.episodes;
    assert.ok(Array.isArray(episodes), "recent_activity should return structured episodes");
    if (episodes.length > 0) {
      const episodeId = episodes[0]?.id;
      assert.equal(typeof episodeId, "string");
      const episode = await client.callTool({
        name: "get_episode",
        arguments: { episode_id: episodeId },
      });
      assert.notEqual(episode.isError, true, "get_episode should reach the Swift API");
      const evidence = await client.callTool({
        name: "get_evidence",
        arguments: { episode_id: episodeId, limit: 5 },
      });
      assert.notEqual(evidence.isError, true, "get_evidence should reach the Swift API");
    }
    const search = await client.callTool({
      name: "search_memory",
      arguments: { query: "mnemos", limit: 2 },
    });
    assert.notEqual(search.isError, true, "search_memory should reach the Swift API");
  } else if (process.env.MNEMOS_EXPECT_API === "0") {
    const recent = await client.callTool({ name: "recent_activity", arguments: { limit: 1 } });
    assert.equal(recent.isError, true, "disabled agent access should return a tool error");
    const text = recent.content.find((item) => item.type === "text")?.text ?? "";
    assert.match(text, /agent access is disabled/i);
  }

  process.stderr.write(`Mnemos MCP smoke test passed (${names.length} tools).\n`);
} finally {
  await client.close();
}

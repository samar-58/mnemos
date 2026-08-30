import assert from "node:assert/strict";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import * as z from "zod/v4";

import { MnemosAPIClient } from "../build/mnemos-api.js";

const envelope = z.object({ data: z.string() });

async function withServer(handler, run) {
  const server = createServer(handler);
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const directory = await mkdtemp(join(tmpdir(), "mnemos-mcp-test-"));
  const configuration = join(directory, "agent-api.json");
  await writeFile(configuration, JSON.stringify({
    apiVersion: 2,
    baseURL: `http://127.0.0.1:${address.port}`,
    bearerToken: "t".repeat(48),
    processID: process.pid,
  }));
  await chmod(configuration, 0o600);
  try {
    await run(new MnemosAPIClient(configuration));
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  }
}

test("rejects malformed JSON", async () => {
  await withServer((_request, response) => response.end("not-json"), async (client) => {
    await assert.rejects(client.get("/test", envelope), /malformed JSON/);
  });
});

test("rejects oversized responses before parsing", async () => {
  await withServer((_request, response) => {
    response.setHeader("content-length", String(3 * 1024 * 1024));
    response.end("too large");
  }, async (client) => {
    await assert.rejects(client.get("/test", envelope), /larger than the adapter limit/);
  });
});

test("retries and reports unauthorized grants", async () => {
  let requests = 0;
  await withServer((_request, response) => {
    requests += 1;
    response.statusCode = 401;
    response.setHeader("content-type", "application/json");
    response.end(JSON.stringify({ error: "A valid bearer token is required." }));
  }, async (client) => {
    await assert.rejects(client.get("/test", envelope), /\(401\).*bearer token/);
    assert.equal(requests, 2);
  });
});

test("reports bounded non-200 API errors without reflecting arbitrary bodies", async () => {
  await withServer((_request, response) => {
    response.statusCode = 503;
    response.end("<html>untrusted upstream content</html>");
  }, async (client) => {
    await assert.rejects(client.get("/test", envelope), /HTTP status 503/);
  });
});

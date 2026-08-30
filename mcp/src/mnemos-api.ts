import { readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, resolve } from "node:path";

import * as z from "zod/v4";

const configurationSchema = z.object({
  apiVersion: z.literal(2),
  baseURL: z.url(),
  bearerToken: z.string().min(40).max(200),
  processID: z.number().int().positive(),
});

type Configuration = z.infer<typeof configurationSchema>;

const MAXIMUM_CONFIGURATION_BYTES = 16 * 1_024;
const MAXIMUM_RESPONSE_BYTES = 2 * 1_024 * 1_024;
const REQUEST_TIMEOUT_MS = 4_000;

export class MnemosAPIError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "MnemosAPIError";
  }
}

export class MnemosAPIClient {
  readonly #configurationPath: string;

  constructor(configurationPath = defaultConfigurationPath()) {
    this.#configurationPath = configurationPath;
  }

  async get<Schema extends z.ZodType>(
    path: string,
    schema: Schema,
    query: Record<string, string | number | boolean | undefined> = {},
  ): Promise<z.infer<Schema>> {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const configuration = await this.#loadConfiguration();
      const url = new URL(path, `${configuration.baseURL}/`);
      for (const [name, value] of Object.entries(query)) {
        if (value !== undefined) url.searchParams.set(name, String(value));
      }

      let response: Response;
      try {
        response = await fetch(url, {
          method: "GET",
          headers: {
            Accept: "application/json",
            Authorization: `Bearer ${configuration.bearerToken}`,
          },
          redirect: "error",
          signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        });
      } catch (error) {
        const detail = error instanceof Error ? error.message : "Connection failed.";
        throw new MnemosAPIError(
          `Could not reach Mnemos. Confirm the app is running and Local agent access is enabled. ${detail}`,
        );
      }

      if (response.status === 401 && attempt === 0) continue;
      const body = await readBoundedBody(response);
      if (!response.ok) {
        throw new MnemosAPIError(apiErrorMessage(response.status, body));
      }

      let value: unknown;
      try {
        value = JSON.parse(body);
      } catch {
        throw new MnemosAPIError("Mnemos returned malformed JSON.");
      }

      const parsed = schema.safeParse(value);
      if (!parsed.success) {
        throw new MnemosAPIError("Mnemos returned an unexpected API response.");
      }
      return parsed.data;
    }

    throw new MnemosAPIError("Mnemos rejected the current connection token. Toggle Local agent access and retry.");
  }

  async #loadConfiguration(): Promise<Configuration> {
    let fileStats;
    try {
      fileStats = await stat(this.#configurationPath);
    } catch {
      throw new MnemosAPIError(
        "Mnemos agent access is disabled. Open Mnemos → Agents and enable Local agent access.",
      );
    }

    if (!fileStats.isFile() || fileStats.size > MAXIMUM_CONFIGURATION_BYTES) {
      throw new MnemosAPIError("The Mnemos agent configuration is invalid.");
    }
    if ((fileStats.mode & 0o077) !== 0) {
      throw new MnemosAPIError("The Mnemos agent configuration has unsafe filesystem permissions.");
    }
    if (typeof process.getuid === "function" && fileStats.uid !== process.getuid()) {
      throw new MnemosAPIError("The Mnemos agent configuration belongs to another user.");
    }

    let raw: string;
    try {
      raw = await readFile(this.#configurationPath, "utf8");
    } catch {
      throw new MnemosAPIError("Could not read the Mnemos agent configuration.");
    }

    let value: unknown;
    try {
      value = JSON.parse(raw);
    } catch {
      throw new MnemosAPIError("The Mnemos agent configuration contains malformed JSON.");
    }
    const parsed = configurationSchema.safeParse(value);
    if (!parsed.success) {
      throw new MnemosAPIError("The Mnemos agent configuration has an unsupported format.");
    }

    validateLoopbackURL(parsed.data.baseURL);
    return parsed.data;
  }
}

function defaultConfigurationPath(): string {
  const override = process.env.MNEMOS_AGENT_CONFIG;
  if (override) return isAbsolute(override) ? override : resolve(override);
  return resolve(homedir(), "Library", "Application Support", "Mnemos", "agent-api.json");
}

function validateLoopbackURL(value: string): void {
  const url = new URL(value);
  if (
    url.protocol !== "http:" ||
    url.hostname !== "127.0.0.1" ||
    url.username !== "" ||
    url.password !== "" ||
    url.pathname !== "/" ||
    url.search !== "" ||
    url.hash !== "" ||
    url.port === ""
  ) {
    throw new MnemosAPIError("The Mnemos agent configuration does not target an IPv4 loopback service.");
  }
}

async function readBoundedBody(response: Response): Promise<string> {
  const declaredLength = response.headers.get("content-length");
  if (declaredLength && Number(declaredLength) > MAXIMUM_RESPONSE_BYTES) {
    throw new MnemosAPIError("Mnemos returned a response larger than the adapter limit.");
  }
  const body = await response.text();
  if (Buffer.byteLength(body, "utf8") > MAXIMUM_RESPONSE_BYTES) {
    throw new MnemosAPIError("Mnemos returned a response larger than the adapter limit.");
  }
  return body;
}

function apiErrorMessage(status: number, body: string): string {
  try {
    const value = JSON.parse(body) as { error?: unknown };
    if (typeof value.error === "string" && value.error.length <= 500) {
      return `Mnemos request failed (${status}): ${value.error}`;
    }
  } catch {
    // The status-only fallback deliberately avoids reflecting an untrusted response body.
  }
  return `Mnemos request failed with HTTP status ${status}.`;
}

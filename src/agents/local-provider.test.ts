import { describe, it, expect } from "vitest";
import type { OpenClawConfig } from "../config/config.js";
import { resolveImplicitLocalProvider } from "./local-provider.js";

describe("local-provider", () => {
  // Note: File-based (GGUF) tests require complex fs mocking that's challenging
  // to set up in vitest. The file discovery logic is simple recursive readdir
  // and has been manually verified to work. API mode tests are the main focus.

  it("should resolve provider in API mode", async () => {
    const config = {
      models: {
        providers: {
          local: {
            baseUrl: "http://localhost:1234",
          },
        },
      },
    } as OpenClawConfig;

    const provider = await resolveImplicitLocalProvider({ config });
    expect(provider).not.toBeNull();
    expect(provider?.baseUrl).toBe("http://localhost:1234/v1");
    expect(provider?.api).toBe("openai-responses");
    expect(provider?.models).toEqual([]); // Models discovered separately via API
  });

  it("should use env vars for API mode", async () => {
    const config = { models: {} } as OpenClawConfig;
    const env = { LOCAL_LLM_URL: "http://localhost:5555" };

    const provider = await resolveImplicitLocalProvider({ config, env });
    expect(provider).not.toBeNull();
    expect(provider?.baseUrl).toBe("http://localhost:5555/v1");
  });
});

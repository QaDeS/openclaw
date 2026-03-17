import { describe, it, expect } from "vitest";
import type { OpenClawConfig } from "../config/config.js";
import { resolveImplicitLmStudioProvider } from "./lmstudio.js";

describe("lmstudio", () => {
  it("should resolve provider in API mode", async () => {
    const config = {
      models: {
        providers: {
          lmstudio: {
            baseUrl: "http://localhost:1234",
          },
        },
      },
    } as unknown as OpenClawConfig;

    const provider = await resolveImplicitLmStudioProvider({ config });
    expect(provider).not.toBeNull();
    expect(provider?.baseUrl).toBe("http://localhost:1234/v1");
    expect(provider?.api).toBe("openai-responses");
    expect(provider?.models).toEqual([]);
  });

  it("should use env vars for API mode", async () => {
    const config = { models: {} } as unknown as OpenClawConfig;
    const env = { LM_STUDIO_URL: "http://localhost:5555" } as NodeJS.ProcessEnv;

    const provider = await resolveImplicitLmStudioProvider({ config, env });
    expect(provider).not.toBeNull();
    expect(provider?.baseUrl).toBe("http://localhost:5555/v1");
  });
});

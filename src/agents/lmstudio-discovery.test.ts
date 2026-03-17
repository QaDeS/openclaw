import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { OpenClawConfig } from "../config/config.js";
import { LmStudioDiscoverySource } from "./lmstudio-discovery.js";

describe("LmStudioDiscoverySource", () => {
  const mockConfig: OpenClawConfig = {
    models: {
      providers: {
        lmstudio: {
          baseUrl: "http://localhost:1234",
        },
      },
    },
  } as unknown as OpenClawConfig;

  beforeEach(() => {
    vi.useFakeTimers();
    (LmStudioDiscoverySource as unknown as { cache: null }).cache = null;
    (
      LmStudioDiscoverySource as unknown as {
        inFlightRequests: Map<string, Promise<unknown>>;
      }
    ).inFlightRequests.clear();
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("should discover models using /api/v1/models and normalize baseUrl", async () => {
    const mockResponse = {
      models: [
        {
          type: "llm",
          key: "qwen2.5-coder-3b-instruct",
          display_name: "Qwen2.5 Coder 3B Instruct",
          max_context_length: 32768,
          capabilities: { vision: false, trained_for_tool_use: false },
        },
        {
          type: "llm",
          key: "llava-v1.5-7b",
          display_name: "Llava v1.5 7B",
          max_context_length: 4096,
          capabilities: { vision: true, trained_for_tool_use: false },
        },
      ],
    };

    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue({
      ok: true,
      json: async () => mockResponse,
    } as Response);

    const source = new LmStudioDiscoverySource();
    const models = await source.discover({ config: mockConfig });

    expect(fetchSpy).toHaveBeenCalledWith(
      "http://localhost:1234/api/v1/models",
      expect.any(Object),
    );
    expect(models).toHaveLength(2);
    expect(models[0].id).toBe("qwen2.5-coder-3b-instruct");
    expect(models[0].input).toEqual(["text"]);
    expect(models[1].input).toEqual(["text", "image"]);
  });

  it("should cache discovery results for 5 seconds", async () => {
    const mockResponse = { models: [] };
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue({
      ok: true,
      json: async () => mockResponse,
    } as Response);

    const source = new LmStudioDiscoverySource();

    await source.discover({ config: mockConfig });
    expect(fetchSpy).toHaveBeenCalledTimes(1);

    await source.discover({ config: mockConfig });
    expect(fetchSpy).toHaveBeenCalledTimes(1);

    vi.advanceTimersByTime(6000);

    await source.discover({ config: mockConfig });
    expect(fetchSpy).toHaveBeenCalledTimes(2);
  });

  it("should handle concurrent requests to the same URL", async () => {
    const mockResponse = { models: [] };
    let resolveFetch: (value: Response) => void;
    const fetchPromise = new Promise<Response>((resolve) => {
      resolveFetch = resolve;
    });

    const fetchSpy = vi.spyOn(globalThis, "fetch").mockReturnValue(fetchPromise);

    const source = new LmStudioDiscoverySource();

    const p1 = source.discover({ config: mockConfig });
    const p2 = source.discover({ config: mockConfig });

    resolveFetch!({
      ok: true,
      json: async () => mockResponse,
    } as Response);

    await Promise.all([p1, p2]);

    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });

  it("should strip /v1 from baseUrl for discovery", async () => {
    const configWithV1: OpenClawConfig = {
      models: {
        providers: {
          lmstudio: {
            baseUrl: "http://localhost:1234/v1",
          },
        },
      },
    } as unknown as OpenClawConfig;

    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue({
      ok: true,
      json: async () => ({ models: [] }),
    } as Response);

    const source = new LmStudioDiscoverySource();
    await source.discover({ config: configWithV1 });

    expect(fetchSpy).toHaveBeenCalledWith(
      "http://localhost:1234/api/v1/models",
      expect.any(Object),
    );
  });
});

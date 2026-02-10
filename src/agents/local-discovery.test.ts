import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { OpenClawConfig } from "../config/config.js";
import { LocalDiscoverySource } from "./local-discovery.js";

describe("LocalDiscoverySource", () => {
  const mockConfig: OpenClawConfig = {
    models: {
      providers: {
        local: {
          baseUrl: "http://localhost:1234",
        },
      },
    },
  } as any;

  beforeEach(() => {
    vi.useFakeTimers();
    // Restricting access to internal static state for testing purposes
    (LocalDiscoverySource as any).cache = null;
    (LocalDiscoverySource as any).inFlightRequests.clear();
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("should discover models using LM Studio /api/v1/models and normalize baseUrl", async () => {
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
    } as any);

    const source = new LocalDiscoverySource();
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

  it("should fall back to OpenAI-compatible /v1/models", async () => {
    const openAiResponse = {
      data: [
        { id: "my-model.gguf", object: "model", owned_by: "llamacpp" },
      ],
      object: "list",
    };

    const fetchSpy = vi.spyOn(globalThis, "fetch")
      // First call: LM Studio native API fails
      .mockResolvedValueOnce({ ok: false, status: 404 } as any)
      // Second call: OpenAI-compatible API succeeds
      .mockResolvedValueOnce({
        ok: true,
        json: async () => openAiResponse,
      } as any);

    const source = new LocalDiscoverySource();
    const models = await source.discover({ config: mockConfig });

    expect(fetchSpy).toHaveBeenCalledTimes(2);
    expect(fetchSpy).toHaveBeenCalledWith(
      "http://localhost:1234/v1/models",
      expect.any(Object),
    );
    expect(models).toHaveLength(1);
    expect(models[0].id).toBe("my-model.gguf");
    expect(models[0].provider).toBe("local");
  });

  it("should cache discovery results for 5 seconds", async () => {
    const mockResponse = { models: [] };
    // LM Studio API returns empty, then OpenAI-compatible also returns empty
    const fetchSpy = vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce({ ok: true, json: async () => mockResponse } as any)
      .mockResolvedValueOnce({ ok: true, json: async () => ({ data: [] }) } as any)
      // After cache expiry
      .mockResolvedValueOnce({ ok: true, json: async () => mockResponse } as any)
      .mockResolvedValueOnce({ ok: true, json: async () => ({ data: [] }) } as any);

    const source = new LocalDiscoverySource();

    // First call
    await source.discover({ config: mockConfig });
    expect(fetchSpy).toHaveBeenCalledTimes(2);

    // Second call immediately after (cached)
    await source.discover({ config: mockConfig });
    expect(fetchSpy).toHaveBeenCalledTimes(2);

    // Advance time by 6 seconds
    vi.advanceTimersByTime(6000);

    // Third call after cache expiry
    await source.discover({ config: mockConfig });
    expect(fetchSpy).toHaveBeenCalledTimes(4);
  });

  it("should handle concurrent requests to the same URL", async () => {
    const mockResponse = { models: [] };
    let resolveFetch: (value: any) => void;
    const fetchPromise = new Promise((resolve) => {
      resolveFetch = resolve;
    });

    const fetchSpy = vi.spyOn(globalThis, "fetch").mockReturnValue(fetchPromise as any);

    const source = new LocalDiscoverySource();

    // Start two concurrent discovery calls
    const p1 = source.discover({ config: mockConfig });
    const p2 = source.discover({ config: mockConfig });

    // Complete the fetch
    resolveFetch!({
      ok: true,
      json: async () => mockResponse,
    });

    await Promise.all([p1, p2]);

    // Should only have one fetch call
    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });

  it("should strip /v1 from baseUrl for discovery", async () => {
    const configWithV1: OpenClawConfig = {
      models: {
        providers: {
          local: {
            baseUrl: "http://localhost:1234/v1",
          },
        },
      },
    } as any;

    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue({
      ok: true,
      json: async () => ({ models: [] }),
    } as any);

    const source = new LocalDiscoverySource();
    await source.discover({ config: configWithV1 });

    expect(fetchSpy).toHaveBeenCalledWith(
      "http://localhost:1234/api/v1/models",
      expect.any(Object),
    );
  });
});

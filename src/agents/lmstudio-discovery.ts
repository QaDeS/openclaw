import type { OpenClawConfig } from "../config/config.js";
import type { DiscoveredModel, ModelDiscoverySource } from "./discovery-types.js";
import { resolveImplicitLmStudioProvider } from "./lmstudio.js";

// LM Studio REST API v1 model response type
// See: https://lmstudio.ai/docs/developer/rest/endpoints
type LmStudioModel = {
  type: "llm" | "embedding";
  publisher?: string;
  key: string;
  display_name?: string;
  architecture?: string;
  quantization?: { name: string; bits_per_weight: number };
  max_context_length?: number;
  capabilities?: {
    vision?: boolean;
    trained_for_tool_use?: boolean;
  };
  loaded_instances?: Array<{ id: string }>;
};

type LmStudioModelsResponse = {
  models: LmStudioModel[];
};

async function fetchWithTimeout(
  url: string,
  options: RequestInit,
  timeoutMs: number,
): Promise<Response> {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timeoutId);
  }
}

export class LmStudioDiscoverySource implements ModelDiscoverySource {
  private static cache: {
    models: DiscoveredModel[];
    expiresAt: number;
    baseUrl?: string;
  } | null = null;

  private static inFlightRequests = new Map<string, Promise<DiscoveredModel[]>>();

  async discover(context: {
    config?: OpenClawConfig;
    env?: NodeJS.ProcessEnv;
  }): Promise<DiscoveredModel[]> {
    const results: DiscoveredModel[] = [];
    try {
      if (!context.config) {
        return [];
      }
      const provider = await resolveImplicitLmStudioProvider({
        config: context.config,
        env: context.env,
      });

      if (provider?.baseUrl?.startsWith("http")) {
        // API-based discovery: use LM Studio native API for detailed model info
        const headers: Record<string, string> = {};
        const apiKeyStr =
          typeof provider.apiKey === "string" ? provider.apiKey : String(provider.apiKey ?? "");
        if (apiKeyStr) {
          headers["Authorization"] = `Bearer ${apiKeyStr}`;
        }

        // Normalize baseUrl to strip trailing slashes and /v1 suffix for discovery
        const discoveryBaseUrl = provider.baseUrl.replace(/\/+$/, "").replace(/\/v1$/, "");

        // Check cache (5s TTL)
        const now = Date.now();
        if (
          LmStudioDiscoverySource.cache &&
          LmStudioDiscoverySource.cache.baseUrl === discoveryBaseUrl &&
          LmStudioDiscoverySource.cache.expiresAt > now
        ) {
          return LmStudioDiscoverySource.cache.models;
        }

        // Handle concurrent same-URL requests
        const inFlight = LmStudioDiscoverySource.inFlightRequests.get(discoveryBaseUrl);
        if (inFlight) {
          return inFlight;
        }

        const fetchPromise = (async () => {
          try {
            const discovered = await this.discoverFromLmStudioApi(discoveryBaseUrl, headers);
            const finalResults: DiscoveredModel[] = [];
            if (discovered.length > 0) {
              finalResults.push(...discovered);
            } else {
              // LM Studio configured but no models found.
              finalResults.push({
                id: "(no models loaded)",
                name: "LM Studio (start server and load a model)",
                provider: "lmstudio",
                contextWindow: 128000,
                input: ["text"],
              });
            }

            LmStudioDiscoverySource.cache = {
              models: finalResults,
              expiresAt: Date.now() + 5000,
              baseUrl: discoveryBaseUrl,
            };
            return finalResults;
          } finally {
            LmStudioDiscoverySource.inFlightRequests.delete(discoveryBaseUrl);
          }
        })();

        LmStudioDiscoverySource.inFlightRequests.set(discoveryBaseUrl, fetchPromise);
        return fetchPromise;
      }
    } catch (err) {
      console.warn("[discovery] Failed to resolve LM Studio models:", err);
    }
    return results;
  }

  private async discoverFromLmStudioApi(
    baseUrl: string,
    headers: Record<string, string>,
  ): Promise<DiscoveredModel[]> {
    const results: DiscoveredModel[] = [];

    const url = `${baseUrl}/api/v1/models`;
    try {
      const response = await fetchWithTimeout(url, { method: "GET", headers }, 2000);

      if (!response.ok) {
        console.warn(`[lmstudio] ${url} returned ${response.status}`);
        return results;
      }

      const data = (await response.json()) as LmStudioModelsResponse;
      if (!Array.isArray(data.models)) {
        console.warn(`[lmstudio] ${url} response missing models array:`, Object.keys(data));
        return results;
      }

      // Filter out embedding models
      const chatModels = data.models.filter((m) => m.type !== "embedding");
      for (const model of chatModels) {
        results.push({
          id: model.key,
          name: model.display_name ?? model.key,
          provider: "lmstudio",
          contextWindow: model.max_context_length,
          input: model.capabilities?.vision ? ["text", "image"] : ["text"],
          reasoning: this.isReasoningModel(model),
        });
      }
    } catch (err) {
      console.warn(`[lmstudio] Failed to fetch ${url}:`, err);
    }

    return results;
  }

  private isReasoningModel(model: LmStudioModel): boolean {
    const key = model.key.toLowerCase();
    const arch = model.architecture?.toLowerCase() ?? "";

    return (
      key.includes("r1") ||
      key.includes("reasoning") ||
      key.includes("qwq") ||
      key.includes("deepseek-r") ||
      arch.includes("r1")
    );
  }
}

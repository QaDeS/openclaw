import type { OpenClawConfig } from "../config/config.js";
import type { ModelDiscoverySource, DiscoveredModel } from "./discovery-types.js";
import { resolveImplicitLocalProvider } from "./local-provider.js";

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

// OpenAI-compatible /v1/models response (llama.cpp, vLLM, etc.)
type OpenAiCompatibleModel = {
  id: string;
  object: string;
  owned_by?: string;
};

type OpenAiCompatibleModelsResponse = {
  data: OpenAiCompatibleModel[];
  object: string;
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

export class LocalDiscoverySource implements ModelDiscoverySource {
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
      const provider = await resolveImplicitLocalProvider({
        config: context.config,
        env: context.env,
      });

      if (provider?.models && provider.models.length > 0) {
        // File-based models (pre-discovered in resolveImplicitLocalProvider)
        for (const model of provider.models) {
          results.push({
            id: model.id,
            name: model.name,
            provider: "local",
            contextWindow: model.contextWindow,
            reasoning: model.reasoning,
            input: model.input,
          });
        }
      } else if (provider?.baseUrl?.startsWith("http")) {
        // API-based discovery
        const headers: Record<string, string> = {};
        if (provider.apiKey) {
          headers["Authorization"] = `Bearer ${provider.apiKey}`;
        }

        // Normalize baseUrl to strip trailing slashes and /v1 suffix for discovery
        const discoveryBaseUrl = provider.baseUrl.replace(/\/+$/, "").replace(/\/v1$/, "");

        // Check cache (5s TTL)
        const now = Date.now();
        if (
          LocalDiscoverySource.cache &&
          LocalDiscoverySource.cache.baseUrl === discoveryBaseUrl &&
          LocalDiscoverySource.cache.expiresAt > now
        ) {
          return LocalDiscoverySource.cache.models;
        }

        // Handle concurrent same-URL requests
        const inFlight = LocalDiscoverySource.inFlightRequests.get(discoveryBaseUrl);
        if (inFlight) {
          return inFlight;
        }

        const fetchPromise = (async () => {
          try {
            // Try LM Studio native API first (richer metadata), then OpenAI-compatible fallback
            let discovered = await this.discoverFromLmStudioApi(discoveryBaseUrl, headers);
            if (discovered.length === 0) {
              discovered = await this.discoverFromOpenAiCompatibleApi(discoveryBaseUrl, headers);
            }

            const finalResults: DiscoveredModel[] = [];
            if (discovered.length > 0) {
              finalResults.push(...discovered);
            } else {
              // Server configured but no models found (server down or no models loaded).
              // Return a placeholder so the provider appears in model selection UI.
              finalResults.push({
                id: "(no models loaded)",
                name: "Local LLM (start server and load a model)",
                provider: "local",
                contextWindow: 128000,
                input: ["text"],
              });
            }

            // Update cache
            LocalDiscoverySource.cache = {
              models: finalResults,
              expiresAt: Date.now() + 5000,
              baseUrl: discoveryBaseUrl,
            };
            return finalResults;
          } finally {
            LocalDiscoverySource.inFlightRequests.delete(discoveryBaseUrl);
          }
        })();

        LocalDiscoverySource.inFlightRequests.set(discoveryBaseUrl, fetchPromise);
        return fetchPromise;
      }
    } catch (err) {
      console.warn("[discovery] Failed to resolve local LLM models:", err);
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
      // LM Studio native REST API v1 provides detailed model metadata
      const response = await fetchWithTimeout(url, { method: "GET", headers }, 2000);

      if (!response.ok) {
        return results;
      }

      const data = (await response.json()) as LmStudioModelsResponse;
      if (!Array.isArray(data.models)) {
        return results;
      }

      // Filter out embedding models - they're not useful for chat
      const chatModels = data.models.filter((m) => m.type !== "embedding");
      for (const model of chatModels) {
        results.push({
          id: model.key,
          name: model.display_name ?? model.key,
          provider: "local",
          contextWindow: model.max_context_length,
          input: model.capabilities?.vision ? ["text", "image"] : ["text"],
          reasoning: this.isReasoningModel(model),
        });
      }
    } catch {
      // LM Studio API not available, will try OpenAI-compatible fallback
    }

    return results;
  }

  // Fallback: OpenAI-compatible /v1/models (works with llama.cpp, vLLM, etc.)
  private async discoverFromOpenAiCompatibleApi(
    baseUrl: string,
    headers: Record<string, string>,
  ): Promise<DiscoveredModel[]> {
    const results: DiscoveredModel[] = [];

    const url = `${baseUrl}/v1/models`;
    try {
      const response = await fetchWithTimeout(url, { method: "GET", headers }, 2000);

      if (!response.ok) {
        return results;
      }

      const data = (await response.json()) as OpenAiCompatibleModelsResponse;
      if (!Array.isArray(data.data)) {
        return results;
      }

      for (const model of data.data) {
        const key = model.id.toLowerCase();
        results.push({
          id: model.id,
          name: model.id,
          provider: "local",
          input: ["text"],
          reasoning:
            key.includes("r1") ||
            key.includes("reasoning") ||
            key.includes("qwq") ||
            key.includes("deepseek-r"),
        });
      }
    } catch {
      // OpenAI-compatible API not available either
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

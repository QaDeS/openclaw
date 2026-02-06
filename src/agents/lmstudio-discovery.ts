import type { OpenClawConfig } from "../config/config.js";
import type { ModelDiscoverySource, DiscoveredModel } from "./discovery-types.js";
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

      if (provider?.models && provider.models.length > 0) {
        // File-based models (pre-discovered in resolveImplicitLmStudioProvider)
        for (const model of provider.models) {
          results.push({
            id: model.id,
            name: model.name,
            provider: "lmstudio",
            contextWindow: model.contextWindow,
            reasoning: model.reasoning,
            input: model.input,
          });
        }
      } else if (provider?.baseUrl?.startsWith("http")) {
        // API-based discovery: use LM Studio native API for detailed model info
        const headers: Record<string, string> = {};
        if (provider.apiKey) {
          headers["Authorization"] = `Bearer ${provider.apiKey}`;
        }

        // Strip /v1 suffix for discovery endpoint construction
        const discoveryBaseUrl = provider.baseUrl.replace(/\/v1\/?$/, "");
        const discovered = await this.discoverFromLmStudioApi(discoveryBaseUrl, headers);
        if (discovered.length > 0) {
          results.push(...discovered);
        } else {
          // LM Studio is configured but no models found (server down or no models loaded).
          // Return a placeholder so the provider appears in model selection UI.
          results.push({
            id: "(no models loaded)",
            name: "LM Studio (start server and load a model)",
            provider: "lmstudio",
            contextWindow: 128000,
            input: ["text"],
          });
        }
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

    try {
      // LM Studio native REST API v1 provides detailed model metadata
      // See: https://lmstudio.ai/docs/developer/rest/endpoints
      const response = await fetchWithTimeout(
        `${baseUrl}/api/v1/models`,
        { method: "GET", headers },
        2000,
      );

      if (response.ok) {
        const data = (await response.json()) as LmStudioModelsResponse;
        if (Array.isArray(data.models)) {
          // Filter out embedding models - they're not useful for chat
          const chatModels = data.models.filter((m) => m.type !== "embedding");
          for (const model of chatModels) {
            results.push({
              id: model.key,
              name: model.display_name ?? model.key,
              provider: "lmstudio",
              contextWindow: model.max_context_length,
              // Vision capability from model metadata
              input: model.capabilities?.vision ? ["text", "image"] : ["text"],
              // Detect reasoning models by architecture or key
              reasoning: this.isReasoningModel(model),
            });
          }
        }
      }
    } catch {
      // Server might be down, ignore
    }

    return results;
  }

  private isReasoningModel(model: LmStudioModel): boolean {
    const key = model.key.toLowerCase();
    const arch = model.architecture?.toLowerCase() ?? "";

    // Common reasoning model patterns
    return (
      key.includes("r1") ||
      key.includes("reasoning") ||
      key.includes("qwq") ||
      key.includes("deepseek-r") ||
      arch.includes("r1")
    );
  }
}

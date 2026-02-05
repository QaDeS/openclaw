import type { ModelDiscoverySource, DiscoveredModel } from "./discovery-types.js";
import { resolveImplicitLmStudioProvider } from "./lmstudio.js";
import type { OpenClawConfig } from "../config/config.js";

export class LmStudioDiscoverySource implements ModelDiscoverySource {
    async discover(context: { config?: OpenClawConfig; env?: NodeJS.ProcessEnv }): Promise<DiscoveredModel[]> {
        const results: DiscoveredModel[] = [];
        try {
            if (!context.config) {
                return [];
            }
            const provider = await resolveImplicitLmStudioProvider({
                config: context.config,
                env: context.env,
            });

            if (provider?.models) {
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
                // API-based discovery
                try {
                    // Try to fetch models from LM Studio / OpenAI compatible endpoint
                    // We set a short timeout to avoid blocking startup if server is down
                    const controller = new AbortController();
                    const timeoutId = setTimeout(() => controller.abort(), 1000);

                    const headers: Record<string, string> = {};
                    if (provider.apiKey) {
                        headers["Authorization"] = `Bearer ${provider.apiKey}`;
                    }

                    const response = await fetch(`${provider.baseUrl}/v1/models`, {
                        method: 'GET',
                        headers,
                        signal: controller.signal
                    });
                    clearTimeout(timeoutId);

                    if (response.ok) {
                        const data = await response.json() as { data: Array<{ id: string }> };
                        if (Array.isArray(data.data)) {
                            for (const model of data.data) {
                                results.push({
                                    id: model.id,
                                    name: model.id,
                                    provider: "lmstudio",
                                    contextWindow: 128000, // LM Studio usually handles large context, hard to know exactly without metadata
                                    input: ["text"],
                                });
                            }
                        }
                    }
                } catch (e) {
                    // Ignore API discovery errors (server might be down)
                }
            }
        } catch (err) {
            console.warn("[discovery] Failed to resolve LM Studio models:", err);
        }
        return results;
    }
}

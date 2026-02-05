import type { ModelDiscoverySource, DiscoveredModel } from "./discovery-types.js";
import { resolveImplicitLocalGgufProvider } from "./local-gguf-models.js";
import type { OpenClawConfig } from "../config/config.js";

export class LocalGgufDiscoverySource implements ModelDiscoverySource {
    async discover(context: { config?: OpenClawConfig; env?: NodeJS.ProcessEnv }): Promise<DiscoveredModel[]> {
        const results: DiscoveredModel[] = [];
        try {
            if (!context.config) {
                return [];
            }
            const ggufProvider = await resolveImplicitLocalGgufProvider({
                config: context.config,
                env: context.env,
            });

            if (ggufProvider?.models) {
                for (const model of ggufProvider.models) {
                    results.push({
                        id: model.id,
                        name: model.name,
                        provider: "local-gguf",
                        contextWindow: model.contextWindow,
                        reasoning: model.reasoning,
                        input: model.input,
                    });
                }
            }
        } catch (err) {
            console.warn("[discovery] Failed to resolve local GGUF models:", err);
        }
        return results;
    }
}

import fs from "node:fs/promises";
import path from "node:path";
import type { ModelDefinitionConfig, ProviderConfig } from "../config/types.models.js";
import type { OpenClawConfig } from "../config/config.js";

const GGUF_DEFAULT_CONTEXT_WINDOW = 8192;
const GGUF_DEFAULT_MAX_TOKENS = 4096;
const GGUF_COST = {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
};

// Recursively find all .gguf files
async function findGgufFiles(dir: string): Promise<string[]> {
    const results: string[] = [];
    try {
        const entries = await fs.readdir(dir, { withFileTypes: true });
        for (const entry of entries) {
            const fullPath = path.join(dir, entry.name);
            if (entry.isDirectory()) {
                results.push(...(await findGgufFiles(fullPath)));
            } else if (entry.isFile() && entry.name.toLowerCase().endsWith(".gguf")) {
                results.push(fullPath);
            }
        }
    } catch (error) {
        if ((error as { code?: string }).code !== "ENOENT") {
            console.warn(`Failed to scan directory ${dir}:`, error);
        }
    }
    return results;
}

export async function discoverLocalGgufModels(
    folderPath: string,
): Promise<ModelDefinitionConfig[]> {
    const files = await findGgufFiles(folderPath);
    const models: ModelDefinitionConfig[] = [];

    for (const file of files) {
        // Determine relative path to use as ID (or just filename if simple)
        // For now, let's use the filename as the base ID.
        // If we have duplicates, we can disambiguate.
        const name = path.basename(file, ".gguf");
        const relativePath = path.relative(folderPath, file);

        models.push({
            id: relativePath, // Use relative path as ID to ensure uniqueness
            name: name,
            reasoning: name.toLowerCase().includes("r1") || name.toLowerCase().includes("reasoning"),
            input: ["text"], // Assume text-only for now unless we sniff metadata
            cost: GGUF_COST,
            contextWindow: GGUF_DEFAULT_CONTEXT_WINDOW,
            maxTokens: GGUF_DEFAULT_MAX_TOKENS,
        });
    }

    return models;
}

export async function resolveImplicitLocalGgufProvider(params: {
    config: OpenClawConfig;
    env?: NodeJS.ProcessEnv;
}): Promise<ProviderConfig | null> {
    const providerConfig = params.config.models?.providers?.["local-gguf"];

    // Check for MODEL_PATH env var if no config or if config uses it
    let folderPath: string | undefined;

    if (providerConfig?.baseUrl?.startsWith("file://")) {
        folderPath = providerConfig.baseUrl.slice(7);
    } else if (params.env?.MODEL_PATH) {
        folderPath = params.env.MODEL_PATH;
    }

    if (!folderPath) {
        return null;
    }

    const models = await discoverLocalGgufModels(folderPath);

    if (models.length === 0) {
        return null;
    }

    return {
        baseUrl: `file://${folderPath}`,
        api: "openai-completions",
        models,
    };
}

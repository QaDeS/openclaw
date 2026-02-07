import type { ModelDiscoverySource, DiscoveredModel } from "./discovery-types.js";
import { type OpenClawConfig, loadConfig } from "../config/config.js";
import { resolveOpenClawAgentDir } from "./agent-paths.js";
import { LmStudioDiscoverySource } from "./lmstudio-discovery.js";
import { resolveImplicitLmStudioProvider } from "./lmstudio.js";
import { ensureOpenClawModelsJson } from "./models-config.js";

export type ModelCatalogEntry = {
  id: string;
  name: string;
  provider: string;
  contextWindow?: number;
  reasoning?: boolean;
  input?: Array<"text" | "image">;
};

type PiSdkModule = typeof import("./pi-model-discovery.js");

let modelCatalogPromise: Promise<ModelCatalogEntry[]> | null = null;
let hasLoggedModelCatalogError = false;
const defaultImportPiSdk = () => import("./pi-model-discovery.js");
let importPiSdk = defaultImportPiSdk;

export function resetModelCatalogCacheForTest() {
  modelCatalogPromise = null;
  hasLoggedModelCatalogError = false;
  importPiSdk = defaultImportPiSdk;
}

// Test-only escape hatch: allow mocking the dynamic import to simulate transient failures.
export function __setModelCatalogImportForTest(loader?: () => Promise<PiSdkModule>) {
  importPiSdk = loader ?? defaultImportPiSdk;
}

export async function loadModelCatalog(params?: {
  config?: OpenClawConfig;
  useCache?: boolean;
}): Promise<ModelCatalogEntry[]> {
  if (params?.useCache === false) {
    modelCatalogPromise = null;
  }
  if (modelCatalogPromise) {
    return modelCatalogPromise;
  }

  modelCatalogPromise = (async () => {
    const models: ModelCatalogEntry[] = [];
    const sortModels = (entries: ModelCatalogEntry[]) =>
      entries.sort((a, b) => {
        const p = a.provider.localeCompare(b.provider);
        if (p !== 0) {
          return p;
        }
        return a.name.localeCompare(b.name);
      });

    try {
      const cfg = params?.config ?? loadConfig();
      await ensureOpenClawModelsJson(cfg);

      // Discovery sources
      const sources: ModelDiscoverySource[] = [
        // PI SDK Adapter
        {
          async discover() {
            // IMPORTANT: keep the dynamic import *inside* the try/catch.
            const piSdk = await importPiSdk();
            const agentDir = resolveOpenClawAgentDir();
            const { join } = await import("node:path");
            const authStorage = new piSdk.AuthStorage(join(agentDir, "auth.json"));
            const registry = new piSdk.ModelRegistry(authStorage, join(agentDir, "models.json")) as
              | { getAll: () => Array<DiscoveredModel> }
              | Array<DiscoveredModel>;

            const entries = Array.isArray(registry) ? registry : registry.getAll();
            // Map to shared type if strictly necessary, but shapes match
            return entries as DiscoveredModel[];
          },
        },
        // LM Studio (local models)
        new LmStudioDiscoverySource(),
      ];

      for (const source of sources) {
        try {
          const discovered = await source.discover({ config: cfg, env: process.env });
          for (const entry of discovered) {
            const id = String(entry?.id ?? "").trim();
            if (!id) continue;
            const provider = String(entry?.provider ?? "").trim();
            if (!provider) continue;

            const name = String(entry?.name ?? id).trim() || id;
            models.push({
              id,
              name,
              provider,
              contextWindow: entry.contextWindow,
              reasoning: entry.reasoning,
              input: entry.input,
            });
          }
        } catch (e) {
          console.warn(`[model-catalog] Source failed:`, e);
        }
      }

      if (models.length === 0) {
        modelCatalogPromise = null;
      }
      return sortModels(models);
    } catch (error) {
      // ... existing error handling ...
      if (!hasLoggedModelCatalogError) {
        hasLoggedModelCatalogError = true;
        console.warn(`[model-catalog] Failed to load model catalog: ${String(error)}`);
      }
      modelCatalogPromise = null;
      return models.length > 0 ? sortModels(models) : [];
    }
  })();

  return modelCatalogPromise;
}

/**
 * Check if a model supports image input based on its catalog entry.
 */
export function modelSupportsVision(entry: ModelCatalogEntry | undefined): boolean {
  return entry?.input?.includes("image") ?? false;
}

/**
 * Find a model in the catalog by provider and model ID.
 */
export function findModelInCatalog(
  catalog: ModelCatalogEntry[],
  provider: string,
  modelId: string,
): ModelCatalogEntry | undefined {
  const normalizedProvider = provider.toLowerCase().trim();
  const normalizedModelId = modelId.toLowerCase().trim();
  return catalog.find(
    (entry) =>
      entry.provider.toLowerCase() === normalizedProvider &&
      entry.id.toLowerCase() === normalizedModelId,
  );
}

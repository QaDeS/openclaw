
import { log } from "./pi-embedded-runner/logger.js";

// Define simplified types for node-llama-cpp to avoid hard dependency imports here
type LlamaModel = any;
type Llama = any;

interface LoadedModel {
    model: LlamaModel;
    lastUsed: number;
    path: string;
}

const DEFAULT_MAX_CACHED_MODELS = 5;

export class LmStudioModelManager {
    private static instance: LmStudioModelManager;
    private loadedModels: Map<string, LoadedModel> = new Map();
    private llama: Llama | null = null;
    private nodeLlama: any = null;
    private maxCachedModels = DEFAULT_MAX_CACHED_MODELS;

    private constructor() { }

    static getInstance(): LmStudioModelManager {
        if (!LmStudioModelManager.instance) {
            LmStudioModelManager.instance = new LmStudioModelManager();
        }
        return LmStudioModelManager.instance;
    }

    configure(params: { maxCachedModels?: number }) {
        if (typeof params.maxCachedModels === 'number' && params.maxCachedModels > 0) {
            this.maxCachedModels = params.maxCachedModels;
            this.manageCache(); // Trigger eviction if new limit is lower
        }
    }

    async getModel(modelPath: string): Promise<LlamaModel> {
        const existing = this.loadedModels.get(modelPath);
        if (existing) {
            log.info(`[LmStudioModelManager] Reusing loaded model: ${modelPath}`);
            existing.lastUsed = Date.now();
            return existing.model;
        }

        await this.ensureLlama();
        await this.manageCache();

        log.info(`[LmStudioModelManager] Loading model: ${modelPath}`);
        try {
            const model = await this.llama.loadModel({
                modelPath: modelPath,
            });

            this.loadedModels.set(modelPath, {
                model,
                lastUsed: Date.now(),
                path: modelPath
            });

            return model;
        } catch (err) {
            log.error(`[LmStudioModelManager] Failed to load model ${modelPath}:`, err as any);
            throw err;
        }
    }

    private async ensureLlama() {
        if (this.llama) return;

        log.info("[LmStudioModelManager] Initializing node-llama-cpp runtime...");
        this.nodeLlama = await import("node-llama-cpp");
        this.llama = await this.nodeLlama.getLlama();
    }

    async unloadModel(modelPath: string) {
        const entry = this.loadedModels.get(modelPath);
        if (entry) {
            log.info(`[LmStudioModelManager] Explicitly unloading model: ${modelPath}`);
            if (typeof entry.model.dispose === 'function') {
                entry.model.dispose();
            }
            this.loadedModels.delete(modelPath);
        }
    }

    async clearCache() {
        log.info("[LmStudioModelManager] Clearing all cached models");
        for (const path of this.loadedModels.keys()) {
            await this.unloadModel(path);
        }
    }

    private async manageCache() {
        if (this.loadedModels.size < this.maxCachedModels) {
            return;
        }

        // Find least recently used model
        let lruPath: string | null = null;
        let oldest = Infinity;

        for (const [path, data] of this.loadedModels.entries()) {
            if (data.lastUsed < oldest) {
                oldest = data.lastUsed;
                lruPath = path;
            }
        }

        if (lruPath) {
            this.unloadModel(lruPath);
        }
    }
}

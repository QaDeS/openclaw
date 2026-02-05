import { describe, it, expect, vi, beforeEach } from "vitest";
import { GgufModelManager } from "./local-gguf-manager.js";

// Mock logger
vi.mock("./pi-embedded-runner/logger.js", () => ({
    log: {
        info: vi.fn(),
        error: vi.fn(),
    },
}));

// Mock node-llama-cpp
const mockDispose = vi.fn();
const mockLoadModel = vi.fn().mockImplementation((opts) => ({
    path: opts.modelPath,
    dispose: mockDispose,
}));
const mockGetLlama = vi.fn().mockResolvedValue({
    loadModel: mockLoadModel,
});

vi.mock("node-llama-cpp", () => ({
    getLlama: mockGetLlama,
}));

describe("GgufModelManager", () => {
    beforeEach(() => {
        vi.clearAllMocks();
        // Reset singleton (hacky but needed for testing singleton state changes)
        (GgufModelManager as any).instance = null;
    });

    it("should be a singleton", () => {
        const instance1 = GgufModelManager.getInstance();
        const instance2 = GgufModelManager.getInstance();
        expect(instance1).toBe(instance2);
    });

    it("should load a model", async () => {
        const manager = GgufModelManager.getInstance();
        const model = await manager.getModel("/path/to/model-a.gguf");

        expect(mockGetLlama).toHaveBeenCalled();
        expect(mockLoadModel).toHaveBeenCalledWith({ modelPath: "/path/to/model-a.gguf" });
        expect(model).toBeDefined();
    });

    it("should cache loaded models", async () => {
        const manager = GgufModelManager.getInstance();
        await manager.getModel("/path/to/model-a.gguf");
        await manager.getModel("/path/to/model-a.gguf");

        expect(mockLoadModel).toHaveBeenCalledTimes(1);
    });

    it("should evict least recently used model when limit reached", async () => {
        const manager = GgufModelManager.getInstance();
        // Default limit is 5, let's configure it to 2 for this test
        manager.configure({ maxCachedModels: 2 });

        await manager.getModel("/path/to/model-1.gguf");
        await manager.getModel("/path/to/model-2.gguf");

        // Touch model 1 to make it recent
        await manager.getModel("/path/to/model-1.gguf");

        // Load model 3, should evict model 2 (LRU)
        await manager.getModel("/path/to/model-3.gguf");

        expect(mockDispose).toHaveBeenCalledTimes(1);

        // Load model 2 again, should trigger load
        await manager.getModel("/path/to/model-2.gguf");
        expect(mockLoadModel).toHaveBeenCalledTimes(4); // 1, 2, 3, 2-again
    });

    it("should explicitly unload a model", async () => {
        const manager = GgufModelManager.getInstance();
        await manager.getModel("/path/to/model-x.gguf");

        await manager.unloadModel("/path/to/model-x.gguf");
        expect(mockDispose).toHaveBeenCalledTimes(1);

        // Should reload if requested again
        await manager.getModel("/path/to/model-x.gguf");
        expect(mockLoadModel).toHaveBeenCalledTimes(2);
    });

    it("should clear cache", async () => {
        const manager = GgufModelManager.getInstance();
        await manager.getModel("/path/to/model-1.gguf");
        await manager.getModel("/path/to/model-2.gguf");

        await manager.clearCache();
        expect(mockDispose).toHaveBeenCalledTimes(2);

        // Should reload
        await manager.getModel("/path/to/model-1.gguf");
        expect(mockLoadModel).toHaveBeenCalledTimes(3);
    });

    it("should respect configured max cached models via configure", async () => {
        const manager = GgufModelManager.getInstance();
        manager.configure({ maxCachedModels: 1 });

        await manager.getModel("/path/to/model-a.gguf");
        await manager.getModel("/path/to/model-b.gguf"); // Evicts A

        expect(mockDispose).toHaveBeenCalledTimes(1);
    });
});

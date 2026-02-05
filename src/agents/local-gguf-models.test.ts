import { describe, it, expect, vi, beforeEach } from "vitest";
import { discoverLocalGgufModels, resolveImplicitLocalGgufProvider } from "./local-gguf-models.js";
// @ts-ignore
import * as fs from "node:fs/promises";
import path from "node:path";

vi.mock("node:fs/promises");

describe("local-gguf-models", () => {
    beforeEach(() => {
        vi.resetAllMocks();
    });

    it("should recursively find gguf files", async () => {
        const mockFiles: Record<string, any[]> = {
            "/models": [
                { name: "model-a.gguf", isFile: () => true, isDirectory: () => false },
                { name: "subdir", isFile: () => false, isDirectory: () => true },
                { name: "ignored.txt", isFile: () => true, isDirectory: () => false }
            ],
            "/models/subdir": [
                { name: "model-b.gguf", isFile: () => true, isDirectory: () => false }
            ]
        };

        (fs.readdir as any).mockImplementation(async (dir: string) => {
            return mockFiles[dir] || [];
        });

        const models = await discoverLocalGgufModels("/models");

        expect(models).toHaveLength(2);
        const ids = models.map(m => m.id).sort();
        expect(ids).toEqual(["model-a.gguf", "subdir/model-b.gguf"]);
        expect(models[0].cost).toBeDefined();
    });

    it("should resolve provider when config is present", async () => {
        (fs.readdir as any).mockImplementation(async () => [
            { name: "test.gguf", isFile: () => true, isDirectory: () => false }
        ]);

        const config: any = {
            models: {
                providers: {
                    "local-gguf": {
                        baseUrl: "file:///models"
                    }
                }
            }
        };

        const provider = await resolveImplicitLocalGgufProvider({ config });
        expect(provider).not.toBeNull();
        expect(provider?.models).toHaveLength(1);
        expect(provider?.models[0].id).toBe("test.gguf");
    });

    it("should return null if no files found", async () => {
        (fs.readdir as any).mockImplementation(async () => []);

        const config: any = {
            models: {
                providers: {
                    "local-gguf": {
                        baseUrl: "file:///models"
                    }
                }
            }
        };

        const provider = await resolveImplicitLocalGgufProvider({ config });
        expect(provider).toBeNull();
    });
});

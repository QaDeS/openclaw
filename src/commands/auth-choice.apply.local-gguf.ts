import fs from "node:fs/promises";
import type { ApplyAuthChoiceParams, ApplyAuthChoiceResult } from "./auth-choice.apply.js";

export async function applyAuthChoiceLocalGguf(
    params: ApplyAuthChoiceParams,
): Promise<ApplyAuthChoiceResult | null> {
    if (params.authChoice !== "local-gguf") {
        return null;
    }

    let config = params.config;
    let modelsDir = "";

    while (!modelsDir) {
        const input = await params.prompter.text({
            message: "Enter the absolute path to your GGUF models folder",
            validate: (value) => (value?.trim() ? undefined : "Path is required"),
        });

        if (typeof input === "symbol") {
            throw new Error("Aborted");
        }

        const resolved = String(input).trim();
        try {
            const stats = await fs.stat(resolved);
            if (!stats.isDirectory()) {
                await params.prompter.note(`Path exists but is not a directory: ${resolved}`, "Error");
                continue;
            }
            modelsDir = resolved;
        } catch {
            await params.prompter.note(`Path does not exist: ${resolved}`, "Error");
        }
    }

    config = {
        ...config,
        models: {
            ...config.models,
            providers: {
                ...config.models?.providers,
                "local-gguf": {
                    baseUrl: `file://${modelsDir}`,
                    api: "openai-completions", // We'll hijack this in the runner
                    models: [], // Discovery happens at runtime
                },
            },
        },
    };

    return { config, agentModelOverride: undefined };
}

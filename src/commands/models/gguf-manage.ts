import type { RuntimeEnv } from "../../runtime.js";
import { loadConfig, updateConfig } from "../../config/config.js";
import { callGateway } from "../../gateway/call.js";

export async function modelsGgufUnloadCommand(
    opts: {
        model?: string;
        all?: boolean;
        timeoutMs?: number;
    },
    runtime: RuntimeEnv,
) {
    if (!opts.model && !opts.all) {
        throw new Error("Specify --model <path> or --all");
    }

    const result = await callGateway<{ message: string }>({
        method: "models.gguf.unload",
        params: {
            modelPath: opts.model,
            all: opts.all,
        },
        timeoutMs: opts.timeoutMs,
    });

    if (result) {
        runtime.log(result.message);
    }
}

export async function modelsGgufConfigCommand(
    opts: {
        limit?: number;
    },
    runtime: RuntimeEnv,
) {
    if (opts.limit === undefined) {
        const cfg = loadConfig();
        const current = cfg.providers?.["local-gguf"]?.maxCachedModels ?? 5;
        runtime.log(`Current GGUF cache limit: ${current}`);
        return;
    }

    const limit = Number(opts.limit);
    if (Number.isNaN(limit) || limit < 1) {
        throw new Error("Limit must be a positive number");
    }

    await updateConfig((cfg) => {
        if (!cfg.providers) {
            cfg.providers = {};
        }
        if (!cfg.providers["local-gguf"]) {
            cfg.providers["local-gguf"] = {};
        }
        // Type assertion or update type definition might be needed if maxCachedModels is not in schema yet
        // Assuming schema allows arbitrary props or I need to update it.
        (cfg.providers["local-gguf"] as any).maxCachedModels = limit;

        // Also, we might want to update the running instance if possible?
        // But modifying config usually requires restart or HUP.
        // However, GgufModelManager is configurable.
        // If the gateway watches config, it might reload.
    });

    runtime.log(`GGUF cache limit set to ${limit}. You may need to restart the agent/gateway for this to take full effect if not dynamically watched.`);
}

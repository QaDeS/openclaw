import type { RuntimeEnv } from "../../runtime.js";
import { loadConfig, writeConfigFile } from "../../config/config.js";
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
        const current = cfg.models?.providers?.["local-gguf"]?.maxCachedModels ?? 5;
        runtime.log(`Current GGUF cache limit: ${current}`);
        return;
    }

    const limit = Number(opts.limit);
    if (Number.isNaN(limit) || limit < 1) {
        throw new Error("Limit must be a positive number");
    }

    const cfg = loadConfig();
    if (!cfg.models) {
        cfg.models = {};
    }
    if (!cfg.models.providers) {
        cfg.models.providers = {};
    }
    if (!cfg.models.providers["local-gguf"]) {
        cfg.models.providers["local-gguf"] = {
            baseUrl: "",
            models: [],
        };
    }
    cfg.models.providers["local-gguf"].maxCachedModels = limit;

    await writeConfigFile(cfg);

    // Also, we might want to update the running instance if possible?
    // But modifying config usually requires restart or HUP.
    // However, GgufModelManager is configurable.
    // If the gateway watches config, it might reload.

    runtime.log(`GGUF cache limit set to ${limit}. You may need to restart the agent/gateway for this to take full effect if not dynamically watched.`);
}

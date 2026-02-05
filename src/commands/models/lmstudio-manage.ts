import type { RuntimeEnv } from "../../runtime.js";
import { loadConfig, writeConfigFile } from "../../config/config.js";
import { callGateway } from "../../gateway/call.js";

export async function modelsLmStudioUnloadCommand(
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
        method: "models.lmstudio.unload",
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

export async function modelsLmStudioConfigCommand(
    opts: {
        url?: string;
        token?: string;
        limit?: number;
    },
    runtime: RuntimeEnv,
) {
    const cfg = loadConfig();

    if (opts.url === undefined && opts.token === undefined && opts.limit === undefined) {
        const current = cfg.models?.providers?.["lmstudio"];
        runtime.log(`Current LM Studio Config:`);
        runtime.log(`  URL:   ${current?.baseUrl || "Not set (local fallback)"}`);
        runtime.log(`  Token: ${current?.apiKey ? "****" : "Not set"}`);
        runtime.log(`  Limit: ${current?.maxCachedModels ?? 5} (GGUF cache)`);
        return;
    }

    if (!cfg.models) cfg.models = {};
    if (!cfg.models.providers) cfg.models.providers = {};
    if (!cfg.models.providers["lmstudio"]) {
        cfg.models.providers["lmstudio"] = {
            baseUrl: "",
            models: [],
        };
    }

    const provider = cfg.models.providers["lmstudio"];

    if (opts.url !== undefined) {
        provider.baseUrl = opts.url;
        runtime.log(`LM Studio URL set to: ${opts.url}`);
    }

    if (opts.token !== undefined) {
        provider.apiKey = opts.token;
        runtime.log(`LM Studio Token updated.`);
    }

    if (opts.limit !== undefined) {
        const limit = Number(opts.limit);
        if (Number.isNaN(limit) || limit < 1) {
            throw new Error("Limit must be a positive number");
        }
        provider.maxCachedModels = limit;
        runtime.log(`GGUF cache limit set to ${limit}.`);
    }

    await writeConfigFile(cfg);
    runtime.log(`\nConfig saved. You may need to restart the agent/gateway for changes to take full effect.`);
}

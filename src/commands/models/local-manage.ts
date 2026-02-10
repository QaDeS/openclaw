import type { RuntimeEnv } from "../../runtime.js";
import { loadConfig, writeConfigFile } from "../../config/config.js";
import { callGateway } from "../../gateway/call.js";

export async function modelsLocalUnloadCommand(
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
    method: "models.local.unload",
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

export async function modelsLocalConfigCommand(
  opts: {
    url?: string;
    token?: string;
    limit?: number;
  },
  runtime: RuntimeEnv,
) {
  const cfg = loadConfig();

  if (opts.url === undefined && opts.token === undefined && opts.limit === undefined) {
    const current = cfg.models?.providers?.["local"];
    runtime.log(`Current Local LLM Config:`);
    runtime.log(`  URL:   ${current?.baseUrl || "Not set (local fallback)"}`);
    runtime.log(`  Token: ${current?.apiKey ? "****" : "Not set"}`);
    runtime.log(`  Limit: ${current?.maxCachedModels ?? 5} (model cache)`);
    return;
  }

  if (!cfg.models) cfg.models = {};
  if (!cfg.models.providers) cfg.models.providers = {};
  if (!cfg.models.providers["local"]) {
    cfg.models.providers["local"] = {
      baseUrl: "",
      models: [],
    };
  }

  const provider = cfg.models.providers["local"];

  if (opts.url !== undefined) {
    provider.baseUrl = opts.url;
    runtime.log(`Local LLM URL set to: ${opts.url}`);
  }

  if (opts.token !== undefined) {
    provider.apiKey = opts.token;
    runtime.log(`Local LLM token updated.`);
  }

  if (opts.limit !== undefined) {
    const limit = Number(opts.limit);
    if (Number.isNaN(limit) || limit < 1) {
      throw new Error("Limit must be a positive number");
    }
    provider.maxCachedModels = limit;
    runtime.log(`Model cache limit set to ${limit}.`);
  }

  await writeConfigFile(cfg);
  runtime.log(
    `\nConfig saved. You may need to restart the agent/gateway for changes to take full effect.`,
  );
}

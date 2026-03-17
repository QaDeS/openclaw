import type { OpenClawConfig } from "../config/config.js";
import type { ModelProviderConfig } from "../config/types.models.js";

export async function resolveImplicitLocalApiProvider(params: {
  config: OpenClawConfig;
  env?: NodeJS.ProcessEnv;
}): Promise<ModelProviderConfig | null> {
  const providerConfig = params.config.models?.providers?.["local-api"];

  // API Mode Check (Explicit config or Env)
  const apiUrl = providerConfig?.baseUrl?.startsWith("http")
    ? providerConfig.baseUrl
    : params.env?.LM_STUDIO_URL || params.env?.LMSTUDIO_API_BASE || params.env?.LOCAL_API_URL;

  if (!apiUrl) {
    return null;
  }

  // Standardize to include /v1 suffix for OpenAI-compatible chat completions
  const normalizedUrl = apiUrl.replace(/\/+$/, "");
  const finalUrl = normalizedUrl.endsWith("/v1") ? normalizedUrl : `${normalizedUrl}/v1`;

  return {
    baseUrl: finalUrl,
    apiKey:
      providerConfig?.apiKey ||
      params.env?.LM_STUDIO_TOKEN ||
      params.env?.LMSTUDIO_API_KEY ||
      params.env?.LOCAL_API_KEY ||
      "none",
    api: (providerConfig?.api ||
      params.env?.LM_STUDIO_API ||
      params.env?.LMSTUDIO_API ||
      "openai-responses") as ModelProviderConfig["api"],
    models: [], // Discovery happens via API probing in discovery source
  };
}

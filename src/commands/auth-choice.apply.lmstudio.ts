import fs from "node:fs/promises";
import type { ApplyAuthChoiceParams, ApplyAuthChoiceResult } from "./auth-choice.apply.js";

export async function applyAuthChoiceLmStudio(
  params: ApplyAuthChoiceParams,
): Promise<ApplyAuthChoiceResult | null> {
  if (params.authChoice !== "lmstudio") {
    return null;
  }

  let config = params.config;

  const mode = await params.prompter.select({
    message: "Connect to LM Studio via:",
    options: [
      { value: "api", label: "Local Server API", hint: "http://localhost:1234 (recommended)" },
      { value: "folder", label: "Model Folder", hint: "Scan local model files directly" },
    ],
  });

  if (mode === "folder") {
    let modelsDir = "";
    while (!modelsDir) {
      const input = await params.prompter.text({
        message: "Enter the absolute path to your local models folder",
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
          lmstudio: {
            baseUrl: `file://${modelsDir}`,
            api: "openai-responses",
            models: [],
          },
        },
      },
    };
  } else {
    const url = await params.prompter.text({
      message: "LM Studio Server URL",
      initialValue: "http://localhost:1234",
      validate: (value) =>
        value?.trim().startsWith("http") ? undefined : "Must be a valid HTTP URL",
    });

    if (typeof url === "symbol") {
      throw new Error("Aborted");
    }

    config = {
      ...config,
      models: {
        ...config.models,
        providers: {
          ...config.models?.providers,
          lmstudio: {
            baseUrl: String(url).trim(),
            api: "openai-responses",
            models: [],
          },
        },
      },
    };
  }

  return { config, agentModelOverride: undefined };
}

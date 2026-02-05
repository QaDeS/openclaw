import type { GatewayRequestHandlers } from "./types.js";
import {
  ErrorCodes,
  errorShape,
  formatValidationErrors,
  validateModelsListParams,
} from "../protocol/index.js";

export const modelsHandlers: GatewayRequestHandlers = {
  "models.list": async ({ params, respond, context }) => {
    if (!validateModelsListParams(params)) {
      respond(
        false,
        undefined,
        errorShape(
          ErrorCodes.INVALID_REQUEST,
          `invalid models.list params: ${formatValidationErrors(validateModelsListParams.errors)}`,
        ),
      );
      return;
    }
    try {
      const models = await context.loadGatewayModelCatalog();
      respond(true, { models }, undefined);
    } catch (err) {
      respond(false, undefined, errorShape(ErrorCodes.UNAVAILABLE, String(err)));
    }
  },
  "models.lmstudio.unload": async ({ params, respond }) => {
    const modelPath = typeof params.modelPath === "string" ? params.modelPath : undefined;
    const all = params.all === true;

    if (!modelPath && !all) {
      respond(
        false,
        undefined,
        errorShape(ErrorCodes.INVALID_REQUEST, "modelPath or all=true required"),
      );
      return;
    }

    try {
      const { LmStudioModelManager } = await import(
        "../../agents/lmstudio-manager.js"
      );
      const manager = LmStudioModelManager.getInstance();
      if (all) {
        await manager.clearCache();
        respond(true, { message: "All local models unloaded" }, undefined);
      } else if (modelPath) {
        await manager.unloadModel(modelPath);
        respond(true, { message: `Model unloaded: ${modelPath}` }, undefined);
      }
    } catch (err) {
      respond(false, undefined, errorShape(ErrorCodes.UNAVAILABLE, String(err)));
    }
  },
};

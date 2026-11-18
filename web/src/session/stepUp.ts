import { useCallback } from "react";
import { ApiError } from "../api/client";
import { href, useRouter } from "../app/router";
import { useSession } from "./session";

// X-3
/** Returns a handler that sends the operator through the Access step-up when the API asks for it, and reports whether it did. */
export function useStepUp(): (error: unknown) => boolean {
  const { startStepUp } = useSession();
  const { location } = useRouter();
  return useCallback(
    (error: unknown) => {
      if (
        !(error instanceof ApiError) ||
        error.code !== "auth_step_up_required"
      )
        return false;
      const query = location.search.toString();
      void startStepUp(href(location.path) + (query ? `?${query}` : ""));
      return true;
    },
    [startStepUp, location],
  );
}

export function problemText(error: unknown): string {
  if (error instanceof ApiError)
    return error.problem?.detail ?? error.problem?.title ?? error.message;
  return String(error);
}

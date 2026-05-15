/** Classification of a thrown session/prompt error. */
export type ApiFailureKind = "overloaded" | "credit" | "other";

/** Structured retry info captured from the SDK's `api_retry` events. */
export interface ApiRetryInfo {
  httpStatus: number | null;
  errorType: string;
}

/** Classify a thrown session/prompt error into one of three buckets so the
 *  three catch sites (inner, inner-fallback, outer) all agree on what's a real
 *  credit/billing exhaustion versus a transient Anthropic outage versus a
 *  generic error.
 *
 *  529 is the killer case here. Anthropic returns 529 for `overloaded_error`
 *  (upstream is down or under-provisioned), but the Claude Agent SDK tags its
 *  `api_retry` events for 529 with `error: "rate_limit"`. If we only look at
 *  errorType we'd treat a server outage as the user running out of credit,
 *  emit `credit_exhausted`, restart the subprocess, and abort every other
 *  in-flight pop-out with "Reconnecting after another session ran out of
 *  credit" — which is exactly what happened in production on 2026-05-14.
 *
 *  We disambiguate by checking httpStatus first and falling back to a literal
 *  "529 Overloaded" / "overloaded_error" check in the message text. Genuine
 *  402/429 paths (real billing or rate-limit-with-resets) still classify as
 *  credit so the existing reset-timestamp UX keeps working.
 *
 *  Anything that is neither overload nor credit returns "other" — the caller
 *  surfaces the raw error message verbatim. The credit regexes are bounded
 *  (`[^.]{0,N}` rather than greedy `.*`) so an unrelated error whose text
 *  merely happens to contain the words "limit" or "balance" across a long
 *  sentence is NOT hijacked into the credit bucket (which would wrongly emit
 *  `credit_exhausted` and restart the subprocess). */
export function classifyApiFailure(
  errMsg: string,
  apiRetryInfo: ApiRetryInfo | null,
): ApiFailureKind {
  const httpStatus = apiRetryInfo?.httpStatus ?? null;
  const errorType = apiRetryInfo?.errorType;

  // Upstream overload — transient, do NOT classify as credit even though the
  // SDK reports errorType="rate_limit" for these.
  if (httpStatus === 529) return "overloaded";
  if (/\b529\b[^.]*overloaded|overloaded_error/i.test(errMsg)) return "overloaded";

  // Real credit / billing / rate-limit-with-resets exhaustion.
  const structuredCredit =
    errorType === "billing_error"
    || httpStatus === 402
    || httpStatus === 429
    || errorType === "rate_limit";
  // Bounded spans (no greedy `.*`): the words must sit close together, so a
  // long unrelated sentence that happens to contain "hit your" … "limit" or
  // "insufficient" … "balance" is left as "other" and surfaced verbatim.
  const regexCredit = /credit balance is too low|insufficient[^.]{0,25}(credit|funds|balance)|you've hit your limit|you have hit your limit|hit your[^.]{0,20}limit|rate.?limit[^.]{0,30}rejected|out of extra usage|unable to verify[^.]{0,20}membership/i.test(errMsg);
  if (structuredCredit || regexCredit) return "credit";

  return "other";
}

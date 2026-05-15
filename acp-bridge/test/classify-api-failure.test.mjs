// Harness for classifyApiFailure — the helper that decides whether a thrown
// session/prompt error is an upstream 529 overload, a real credit/billing
// exhaustion, or an unrelated error that must be surfaced verbatim.
//
// Run with:  npm test   (from acp-bridge/)  — builds first, then node --test.
//
// Imports the COMPILED module so the test exercises exactly what ships in the
// app bundle. `npm test` runs `npm run build` first.

import test from "node:test";
import assert from "node:assert/strict";
import { classifyApiFailure } from "../dist/api-failure.js";

// Each case: [description, errMsg, apiRetryInfo, expectedKind]
const overloadedCases = [
  [
    "structured 529 even when SDK mislabels errorType as rate_limit",
    "Overloaded",
    { httpStatus: 529, errorType: "rate_limit" },
    "overloaded",
  ],
  [
    "structured 529 with empty message",
    "",
    { httpStatus: 529, errorType: "" },
    "overloaded",
  ],
  [
    "message text: 529 Overloaded, no structured info",
    "API Error 529 Overloaded",
    null,
    "overloaded",
  ],
  [
    "message text: overloaded_error literal, no structured info",
    "Anthropic returned overloaded_error",
    null,
    "overloaded",
  ],
  [
    "529 overload wins over a credit-looking message",
    "529 overloaded — you have hit your limit",
    { httpStatus: 529, errorType: "rate_limit" },
    "overloaded",
  ],
];

const creditCases = [
  [
    "structured billing_error",
    "request failed",
    { httpStatus: null, errorType: "billing_error" },
    "credit",
  ],
  [
    "structured 402",
    "payment required",
    { httpStatus: 402, errorType: "" },
    "credit",
  ],
  [
    "structured 429 rate limit",
    "too many requests",
    { httpStatus: 429, errorType: "rate_limit" },
    "credit",
  ],
  [
    "regex: credit balance is too low",
    "Your credit balance is too low to access the Anthropic API",
    null,
    "credit",
  ],
  [
    "regex: hit your usage limit (words close together)",
    "You've hit your usage limit. Resets at 5pm.",
    null,
    "credit",
  ],
  [
    "regex: insufficient credit (words adjacent)",
    "insufficient credit on your account",
    null,
    "credit",
  ],
  [
    "regex: out of extra usage",
    "You are out of extra usage for this period",
    null,
    "credit",
  ],
];

// The cases the user cares about: anything NOT overload/credit must come back
// as "other" so the caller surfaces the raw error message unchanged.
const otherCases = [
  ["plain network failure", "fetch failed: ECONNREFUSED", null, "other"],
  ["socket timeout", "Request timed out after 60000ms", null, "other"],
  [
    "generic 500",
    "API Error: 500 Internal Server Error",
    { httpStatus: 500, errorType: "api_error" },
    "other",
  ],
  [
    "400 invalid request (not billing/rate)",
    "API Error: 400 invalid_request_error — messages: text content blocks must be non-empty",
    { httpStatus: 400, errorType: "invalid_request" },
    "other",
  ],
  ["tool failure", "Tool execute_sql failed: no such table", null, "other"],
  ["empty message, no info", "", null, "other"],
  // Adversarial: unrelated errors whose text merely CONTAINS the words
  // "limit" / "balance" far from the trigger phrase. A greedy `.*` regex
  // would hijack these into the credit bucket (→ credit_exhausted + a
  // needless subprocess restart). The bounded `[^.]{0,N}` spans keep them
  // classified as "other".
  [
    "adversarial: 'hit your' and 'limit' far apart in unrelated text",
    "Could not hit your custom endpoint; the upstream proxy enforced a strict request size limit",
    null,
    "other",
  ],
  [
    "adversarial: 'insufficient' and 'balance' far apart in unrelated text",
    "insufficient permissions to read the file; the account has no balance constraints configured",
    null,
    "other",
  ],
  [
    "adversarial: 'rate limit' and 'rejected' far apart in unrelated text",
    "rate limiting is disabled, but the webhook handler rejected the malformed payload",
    null,
    "other",
  ],
];

test("529 overloads classify as 'overloaded'", () => {
  for (const [desc, msg, info, expected] of overloadedCases) {
    assert.equal(classifyApiFailure(msg, info), expected, desc);
  }
});

test("genuine credit/billing/rate errors classify as 'credit'", () => {
  for (const [desc, msg, info, expected] of creditCases) {
    assert.equal(classifyApiFailure(msg, info), expected, desc);
  }
});

test("unrelated errors classify as 'other' and pass through verbatim", () => {
  for (const [desc, msg, info, expected] of otherCases) {
    assert.equal(classifyApiFailure(msg, info), expected, desc);
  }
});

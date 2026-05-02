// Quick unit-test of stripHarnessPrefix against the actual leaked message
// pulled from the user's chat DB. Runs the function against the real bytes
// AND simulates streaming (chunked input) to make sure the buffering logic
// behaves correctly.
import { readFileSync } from "node:fs";

// Inline copy of stripHarnessPrefix (kept in sync with src/index.ts manually
// for now — it's a leaf function with no deps so duplicating is cheap).
function stripHarnessPrefix(buf) {
  const trimmed = buf.trimStart();
  const startsWithHarness =
    trimmed.startsWith("(your turn") ||
    trimmed.startsWith("<system-reminder>") ||
    (trimmed.startsWith("(") && trimmed.length < "(your turn".length) ||
    (trimmed.startsWith("<") && trimmed.length < "<system-reminder>".length);
  if (!startsWithHarness) return { done: true, suffix: buf };

  let pos = 0;
  while (pos < buf.length && /\s/.test(buf.charAt(pos))) pos++;

  if (buf.startsWith("(your turn", pos)) {
    const close = buf.indexOf(")", pos);
    if (close === -1) return { done: false };
    pos = close + 1;
    while (pos < buf.length && /\s/.test(buf.charAt(pos))) pos++;
  }

  while (buf.startsWith("<system-reminder>", pos)) {
    const close = buf.indexOf("</system-reminder>", pos);
    if (close === -1) return { done: false };
    pos = close + "</system-reminder>".length;
    while (pos < buf.length && /\s/.test(buf.charAt(pos))) pos++;
  }

  if (pos < buf.length) {
    const next = buf.charAt(pos);
    if (next === "<" && buf.length - pos < "<system-reminder>".length) {
      return { done: false };
    }
    return { done: true, suffix: buf.slice(pos) };
  }
  return { done: false };
}

function assert(cond, label) {
  if (!cond) {
    console.error(`FAIL: ${label}`);
    process.exitCode = 1;
  } else {
    console.log(`ok   ${label}`);
  }
}

// --- Test 1: full message in one shot ---
const fullLeaked = readFileSync("/tmp/leaked-message.txt", "utf8");
const r1 = stripHarnessPrefix(fullLeaked);
assert(r1.done === true, "[1] one-shot: done=true");
assert(!r1.suffix.includes("(your turn"), "[1] one-shot: stripped 'your turn' line");
assert(!r1.suffix.includes("<system-reminder>"), "[1] one-shot: stripped <system-reminder>");
assert(r1.suffix.startsWith("you're right"), "[1] one-shot: real content preserved at start");

// --- Test 2: streaming, 50-byte chunks ---
let buf = "";
let emittedSoFar = "";
let stripDone = false;
const CHUNK = 50;
for (let i = 0; i < fullLeaked.length; i += CHUNK) {
  const piece = fullLeaked.slice(i, i + CHUNK);
  if (stripDone) { emittedSoFar += piece; continue; }
  buf += piece;
  const r = stripHarnessPrefix(buf);
  if (r.done) {
    emittedSoFar += r.suffix;
    stripDone = true;
    buf = "";
  }
}
if (!stripDone && buf.length > 0) emittedSoFar += buf;
assert(stripDone === true, "[2] streaming: strip resolved");
assert(!emittedSoFar.includes("<system-reminder>"), "[2] streaming: no <system-reminder> leak");
assert(!emittedSoFar.includes("(your turn"), "[2] streaming: no 'your turn' leak");
assert(emittedSoFar.startsWith("you're right"), "[2] streaming: real content kept");

// --- Test 3: normal text (no leak) — must pass through immediately ---
const normal = "Hello! This is a normal answer.";
const r3 = stripHarnessPrefix(normal);
assert(r3.done === true && r3.suffix === normal, "[3] normal text passes through unchanged");

// --- Test 4: streamed normal text — first chunk must emit immediately ---
const r4 = stripHarnessPrefix("Hello!");
assert(r4.done === true && r4.suffix === "Hello!", "[4] streamed normal first chunk emits immediately");

// --- Test 5: leading whitespace before harness ---
const padded = "\n\n" + fullLeaked;
const r5 = stripHarnessPrefix(padded);
assert(r5.done === true && !r5.suffix.includes("<system-reminder>"), "[5] leading whitespace + harness");

// --- Test 6: just `(your turn` — partial, must keep buffering ---
const r6 = stripHarnessPrefix("(your turn");
assert(r6.done === false, "[6] partial '(your turn' buffers");

// --- Test 7: just `<` — could be partial system-reminder open tag, must buffer ---
const r7 = stripHarnessPrefix("<");
assert(r7.done === false, "[7] lone '<' buffers (might be partial tag)");

// --- Test 8: harness followed by `<` partial — must buffer ---
const r8 = stripHarnessPrefix("<system-reminder>foo</system-reminder>\n<sys");
assert(r8.done === false, "[8] harness + partial next tag buffers");

// --- Test 9: real text starting with `(` — must NOT swallow it forever ---
const r9 = stripHarnessPrefix("(this is just regular text in parens) more text");
assert(r9.done === true, "[9] non-harness parens text passes through");
assert(r9.suffix === "(this is just regular text in parens) more text", "[9] non-harness parens preserved");

console.log(process.exitCode ? "\nFAILED" : "\nALL PASS");

// Quick unit-test of stripHarnessPrefix against the actual leaked message
// pulled from the user's chat DB. Runs the function against the real bytes
// AND simulates streaming (chunked input) to make sure the buffering logic
// behaves correctly.
import { readFileSync } from "node:fs";

// Inline copy of stripHarnessPrefix (kept in sync with src/index.ts manually
// for now — it's a leaf function with no deps so duplicating is cheap).
const HARNESS_PAREN_OPENERS = [
  "(your turn",
  "(your response",
  "(your reply",
  "(your answer",
  "(insert your response",
  "(insert response",
  "(insert reply",
  "(response here",
  "(reply here",
  "(answer here",
  "(my response",
  "(my reply",
  "(my answer",
  "(assistant response",
  "(assistant reply",
];
const MAX_PAREN_OPENER_LEN = Math.max(...HARNESS_PAREN_OPENERS.map((s) => s.length));

function matchParenOpener(buf, pos) {
  for (const opener of HARNESS_PAREN_OPENERS) {
    if (buf.startsWith(opener, pos)) return opener;
  }
  return null;
}

function isPartialParenOpener(s) {
  if (s.length === 0) return false;
  for (const opener of HARNESS_PAREN_OPENERS) {
    if (s.length < opener.length && opener.startsWith(s)) return true;
  }
  return false;
}

function stripHarnessPrefix(buf) {
  const trimmed = buf.trimStart();
  const startsWithHarness =
    matchParenOpener(trimmed, 0) !== null ||
    trimmed.startsWith("<system-reminder>") ||
    isPartialParenOpener(trimmed) ||
    (trimmed.startsWith("<") && trimmed.length < "<system-reminder>".length);
  if (!startsWithHarness) return { done: true, suffix: buf };

  let pos = 0;
  while (pos < buf.length && /\s/.test(buf.charAt(pos))) pos++;

  if (matchParenOpener(buf, pos) !== null) {
    const close = buf.indexOf(")", pos);
    if (close === -1) return { done: false };
    pos = close + 1;
    while (pos < buf.length && /\s/.test(buf.charAt(pos))) pos++;
  } else if (buf.startsWith("(", pos) && buf.length - pos < MAX_PAREN_OPENER_LEN) {
    return { done: false };
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

function streamStrip(input, chunkSize) {
  let buf = "";
  let emitted = "";
  let done = false;
  for (let i = 0; i < input.length; i += chunkSize) {
    const piece = input.slice(i, i + chunkSize);
    if (done) { emitted += piece; continue; }
    buf += piece;
    const r = stripHarnessPrefix(buf);
    if (r.done) {
      emitted += r.suffix;
      done = true;
      buf = "";
    }
  }
  if (!done && buf.length > 0) emitted += buf;
  return { done, emitted };
}

// --- Test 1: full message in one shot (existing leaked-message fixture) ---
let fullLeaked = null;
try {
  fullLeaked = readFileSync("/tmp/leaked-message.txt", "utf8");
} catch {
  console.log("note  /tmp/leaked-message.txt not present, skipping fixture-backed tests");
}
if (fullLeaked) {
  const r1 = stripHarnessPrefix(fullLeaked);
  assert(r1.done === true, "[1] one-shot: done=true");
  assert(!r1.suffix.includes("(your turn"), "[1] one-shot: stripped 'your turn' line");
  assert(!r1.suffix.includes("<system-reminder>"), "[1] one-shot: stripped <system-reminder>");
  assert(r1.suffix.startsWith("you're right"), "[1] one-shot: real content preserved at start");

  const s = streamStrip(fullLeaked, 50);
  assert(s.done === true, "[2] streaming 50-byte chunks: strip resolved");
  assert(!s.emitted.includes("<system-reminder>"), "[2] streaming: no <system-reminder> leak");
  assert(!s.emitted.includes("(your turn"), "[2] streaming: no 'your turn' leak");
  assert(s.emitted.startsWith("you're right"), "[2] streaming: real content kept");

  const padded = "\n\n" + fullLeaked;
  const r5 = stripHarnessPrefix(padded);
  assert(r5.done === true && !r5.suffix.includes("<system-reminder>"), "[5] leading whitespace + harness");
}

// --- Test 3: normal text (no leak) — must pass through immediately ---
const normal = "Hello! This is a normal answer.";
const r3 = stripHarnessPrefix(normal);
assert(r3.done === true && r3.suffix === normal, "[3] normal text passes through unchanged");

// --- Test 4: streamed normal text — first chunk must emit immediately ---
const r4 = stripHarnessPrefix("Hello!");
assert(r4.done === true && r4.suffix === "Hello!", "[4] streamed normal first chunk emits immediately");

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

// --- Test 10: NEW — `(your response here)` followed by actual content ---
//   This is the May 12 2026 pop-out failure mode. Must strip and emit body.
const leak10 = "(your response here)\n\nActual reply body goes here.";
const r10 = stripHarnessPrefix(leak10);
assert(r10.done === true, "[10] one-shot: '(your response here)' stripped");
assert(r10.suffix === "Actual reply body goes here.", "[10] one-shot: body preserved");

// --- Test 11: NEW — same but as a "(" first chunk (chunk-boundary case) ---
const s11 = streamStrip(leak10, 1);
assert(s11.done === true, "[11] streaming 1-byte chunks: '(your response here)' stripped");
assert(s11.emitted === "Actual reply body goes here.", "[11] streaming 1-byte: body preserved");

// --- Test 12: NEW — exact 2-chunk split that bit prod (`(` then rest) ---
const r12a = stripHarnessPrefix("(");
assert(r12a.done === false, "[12] chunk '(' alone buffers");
const r12b = stripHarnessPrefix("(your response here) Hi");
assert(r12b.done === true && r12b.suffix === "Hi", "[12] follow-up chunk completes and strips");

// --- Test 13: NEW — other placeholder variants ---
const variants = [
  "(your reply)",
  "(my response)",
  "(my reply)",
  "(your answer)",
  "(insert your response here)",
  "(insert response)",
  "(response here)",
  "(reply here)",
  "(answer here)",
  "(assistant response)",
];
for (const v of variants) {
  const input = `${v}\nReal text after.`;
  const r = stripHarnessPrefix(input);
  assert(r.done === true && r.suffix === "Real text after.", `[13] strip '${v}'`);
  const s = streamStrip(input, 1);
  assert(s.done === true && s.emitted === "Real text after.", `[13] streaming strip '${v}'`);
}

// --- Test 14: NEW — `(` followed by real prose at a chunk boundary larger
// than MAX_PAREN_OPENER_LEN must NOT be incorrectly buffered forever ---
const prose = "(hello world, this is a regular sentence in parens) more text";
const r14 = stripHarnessPrefix(prose);
assert(r14.done === true && r14.suffix === prose, "[14] long parens prose passes through unchanged");

// --- Test 15: NEW — leading whitespace then '(your response here)' ---
const r15 = stripHarnessPrefix("\n\n(your response here) actual");
assert(r15.done === true && r15.suffix === "actual", "[15] whitespace + placeholder + body");

console.log(process.exitCode ? "\nFAILED" : "\nALL PASS");

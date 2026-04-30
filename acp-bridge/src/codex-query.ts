/**
 * Phase 2.3: minimal query handler for codex-acp.
 *
 * Routed from index.ts when msg.model matches a Codex model id (gpt-*,
 * codex-*, o-*). Lazily spawns the CodexProvider singleton, creates a fresh
 * session per sessionKey, streams text deltas + basic tool activity to Swift
 * using the same outbound message shapes the Claude path emits.
 *
 * Deliberately NOT yet handled (deferred to Phase 2.4):
 *   - System prompt (codex-acp doesn't accept the same field; needs research)
 *   - MCP server passthrough (need to confirm codex's stdio MCP support)
 *   - Session resume across queries (always fresh session)
 *   - Interrupt / cancel
 *   - Cost tracking (no recordLlmUsage equivalent for codex yet)
 *   - priorContext replay
 *   - Tool result hand-off to Swift's fazm_tools relay
 */

import type { QueryMessage, OutboundMessage } from "./protocol.js";
import type { CodexProvider } from "./codex-provider.js";

export interface CodexQueryDeps {
  logErr: (msg: string) => void;
  send: (msg: OutboundMessage) => void;
  sendWithSession: (sessionId: string | undefined, msg: OutboundMessage) => void;
  getProvider: () => CodexProvider;
  buildMcpServers: (
    mode: "ask" | "act",
    cwd: string,
    sessionKey: string,
  ) => Array<Record<string, unknown>>;
}

/** Per-sessionKey codex session pool, kept here so it doesn't leak into index.ts globals. */
interface CodexSessionEntry {
  sessionId: string;
  cwd: string;
  modelId: string;
}
const codexSessions = new Map<string, CodexSessionEntry>();

const CODEX_MODEL_PATTERN = /^(gpt-|codex-|o[0-9]-?)/i;

export function isCodexModel(modelId: string | undefined): boolean {
  if (!modelId) return false;
  return CODEX_MODEL_PATTERN.test(modelId);
}

/** Top-level entrypoint. Mirrors handleQuery's contract: never rejects, sends `error` on failure. */
export async function handleCodexQuery(msg: QueryMessage, deps: CodexQueryDeps): Promise<void> {
  const { logErr, send, sendWithSession, getProvider } = deps;
  const sessionKey = msg.sessionKey ?? msg.model ?? "codex-default";
  const cwd = msg.cwd ?? process.env.HOME ?? process.cwd();
  const modelId = msg.model ?? "gpt-5.4/high";

  let provider: CodexProvider;
  try {
    provider = getProvider();
    provider.start();
    await provider.initialize();
  } catch (err) {
    logErr(`[codex-query] init failed: ${err}`);
    send({ type: "error", message: `Codex unavailable: ${err instanceof Error ? err.message : String(err)}` });
    return;
  }

  // Reuse cached session for the same sessionKey + cwd, otherwise create fresh.
  let entry = codexSessions.get(sessionKey);
  if (entry && (entry.cwd !== cwd || entry.modelId !== modelId)) {
    codexSessions.delete(sessionKey);
    provider.unregisterSessionHandler(entry.sessionId);
    entry = undefined;
  }

  let isNewSession = false;
  if (!entry) {
    try {
      const result = (await provider.request("session/new", {
        cwd,
        // Pass empty list for now. Phase 2.4 will plumb buildMcpServers through
        // once we confirm codex-acp accepts the same stdio MCP shape claude does.
        mcpServers: [],
      })) as { sessionId: string; models?: { currentModelId?: string } };
      entry = { sessionId: result.sessionId, cwd, modelId };
      codexSessions.set(sessionKey, entry);
      isNewSession = true;
      sendWithSession(entry.sessionId, { type: "session_started", sessionKey, isResume: false } as OutboundMessage);
      // Switch the session to the requested model.
      try {
        await provider.request("session/set_model", { sessionId: entry.sessionId, modelId });
      } catch (modelErr) {
        logErr(`[codex-query] session/set_model failed (continuing with default): ${modelErr}`);
      }
    } catch (err) {
      logErr(`[codex-query] session/new failed: ${err}`);
      send({ type: "error", message: `Codex session failed: ${err instanceof Error ? err.message : String(err)}` });
      return;
    }
  }

  const sessionId = entry.sessionId;
  let collectedText = "";
  let lastTextHadContent = false;

  provider.registerSessionHandler(sessionId, (method, params) => {
    if (method !== "session/update") return;
    const p = params as { update?: Record<string, unknown> } | undefined;
    const update = p?.update;
    if (!update) return;

    switch (update.sessionUpdate as string | undefined) {
      case "agent_message_chunk": {
        const content = update.content as { type?: string; text?: string } | undefined;
        const text = content?.text ?? "";
        if (text) {
          if (!lastTextHadContent) {
            // First text after a tool — Claude path emits a boundary here; do the same.
            sendWithSession(sessionId, { type: "text_block_boundary" });
          }
          collectedText += text;
          lastTextHadContent = true;
          sendWithSession(sessionId, { type: "text_delta", text });
        }
        break;
      }
      case "agent_thought_chunk": {
        const content = update.content as { type?: string; text?: string } | undefined;
        const text = content?.text ?? "";
        if (text) sendWithSession(sessionId, { type: "thinking_delta", text });
        break;
      }
      case "tool_call": {
        const toolCallId = (update.toolCallId as string) ?? "";
        const title = (update.title as string) ?? "tool";
        const rawInput = (update.rawInput as Record<string, unknown> | undefined) ?? {};
        sendWithSession(sessionId, {
          type: "tool_use",
          callId: toolCallId,
          name: title,
          input: rawInput,
        });
        sendWithSession(sessionId, {
          type: "tool_activity",
          name: title,
          status: "started",
          toolUseId: toolCallId,
          input: rawInput,
        });
        lastTextHadContent = false;
        break;
      }
      case "tool_call_update": {
        const toolCallId = (update.toolCallId as string) ?? "";
        const title = (update.title as string) ?? "tool";
        const status = (update.status as string) ?? "completed";
        if (status === "completed" || status === "failed" || status === "cancelled") {
          // Best-effort: extract a textual blob from the content array.
          const contentArr = update.content as Array<Record<string, unknown>> | undefined;
          let outputText = "";
          if (Array.isArray(contentArr)) {
            for (const c of contentArr) {
              const inner = c.content as { type?: string; text?: string } | undefined;
              if (inner?.text) outputText += inner.text;
            }
          }
          if (outputText) {
            sendWithSession(sessionId, {
              type: "tool_result_display",
              toolUseId: toolCallId,
              name: title,
              output: outputText,
            });
          }
          sendWithSession(sessionId, {
            type: "tool_activity",
            name: title,
            status: "completed",
            toolUseId: toolCallId,
          });
        }
        break;
      }
      case "usage_update":
      case "available_commands_update":
      case "current_mode_update":
      case "plan":
        // Phase 2.3: ignore. usage_update can drive cost tracking in 2.4.
        break;
      default:
        // Unknown update type — don't crash, just log.
        break;
    }
  });

  try {
    const promptResult = (await provider.request("session/prompt", {
      sessionId,
      prompt: [{ type: "text", text: msg.prompt }],
    })) as { stopReason: string };

    sendWithSession(sessionId, {
      type: "result",
      text: collectedText,
      sessionId,
      costUsd: 0,
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
    });
    if (isNewSession) {
      logErr(`[codex-query] new session ${sessionId.slice(0, 8)} stop=${promptResult.stopReason} chars=${collectedText.length}`);
    }
  } catch (err) {
    logErr(`[codex-query] session/prompt failed: ${err}`);
    send({ type: "error", message: `Codex prompt failed: ${err instanceof Error ? err.message : String(err)}` });
  } finally {
    // Don't unregister the handler — reuse for follow-up prompts on the same sessionKey.
    // Cleanup happens on resetSession or process shutdown (Phase 2.4).
  }
}

/** Drop a cached codex session — used when Swift sends resetSession. */
export function dropCodexSession(sessionKey: string, provider: CodexProvider): void {
  const entry = codexSessions.get(sessionKey);
  if (!entry) return;
  provider.unregisterSessionHandler(entry.sessionId);
  codexSessions.delete(sessionKey);
}

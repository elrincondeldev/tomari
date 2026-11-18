/**
 * Permission prompts the strip can answer. Claude Code runs a PermissionRequest hook alongside its own
 * permission dialog, in a terminal as in the desktop app, and takes whichever answers first: the hook can hold
 * the request while the dialog shows, and answering on either side settles it. The agent holds each request
 * until the user answers it from the strip, answers it in Claude (the session's next event says so), or it
 * times out; a released request returns no decision, which leaves Claude's dialog in charge.
 *
 * Codex is left out: it runs the hook before it shows its own approval, so holding the request would hide it.
 */
import { randomUUID } from "node:crypto";
import type { PermissionPrompt } from "../../shared/protocol.ts";
import type { HookEvent } from "./state.ts";

export type PermissionAnswer = "allow" | "deny";

/** Tools whose permission needs more than allow or deny: Claude takes their answer as `updatedInput`. */
const NEEDS_INPUT = new Set(["AskUserQuestion", "ExitPlanMode"]);

/** Just under the hook's own timeout, so the agent answers before Claude gives up on the hook. */
export const HOLD_MS = 590_000;
const MAX_DETAIL = 4000;

/** Whether the strip can answer this permission request with a plain allow or deny. */
export function answerable(event: HookEvent): boolean {
  return event.hook_event_name === "PermissionRequest" && typeof event.tool_name === "string" && !NEEDS_INPUT.has(event.tool_name);
}

/** What the request asks to do, in full, for the user to read before answering: the command, file, URL or input. */
export function permissionDetail(tool: string, input: unknown): string {
  const i = (input ?? {}) as Record<string, unknown>;
  const str = (v: unknown) => (typeof v === "string" ? v.trim() : "");
  const detail =
    str(i.command) ||
    str(i.file_path) ||
    str(i.notebook_path) ||
    str(i.url) ||
    str(i.query) ||
    str(i.pattern) ||
    (Object.keys(i).length > 0 ? JSON.stringify(i, null, 2) : tool);
  return detail.length <= MAX_DETAIL ? detail : `${detail.slice(0, MAX_DETAIL - 1)}…`;
}

/** The hook's stdout for an answer, as Claude Code reads a PermissionRequest decision. */
export function decisionOutput(answer: PermissionAnswer) {
  const decision = answer === "allow" ? { behavior: "allow" } : { behavior: "deny", message: "The user denied this from Tomari." };
  return { hookSpecificOutput: { hookEventName: "PermissionRequest", decision } };
}

interface Held {
  sessionId: string;
  prompt: PermissionPrompt;
  settle: (answer: PermissionAnswer | null) => void;
}

export class PermissionDesk {
  /** By request id, oldest first. */
  private held = new Map<string, Held>();

  constructor(
    /** Told the prompt a session now shows, or null when it has none left. */
    private onChange: (sessionId: string, prompt: PermissionPrompt | null) => void,
    private holdMs = HOLD_MS,
  ) {}

  /** Holds a request until it is answered or released: the answer, or null for no decision. */
  hold(event: HookEvent, signal?: AbortSignal): Promise<PermissionAnswer | null> {
    const tool = String(event.tool_name ?? "");
    const prompt: PermissionPrompt = { id: randomUUID(), tool, detail: permissionDetail(tool, event.tool_input) };
    const sessionId = event.session_id;
    return new Promise((resolve) => {
      const timer = setTimeout(() => settle(null), this.holdMs);
      const settle = (answer: PermissionAnswer | null) => {
        if (!this.held.delete(prompt.id)) return;
        clearTimeout(timer);
        signal?.removeEventListener("abort", onAbort);
        resolve(answer);
        this.onChange(sessionId, this.current(sessionId));
      };
      // Claude ends the hook once the dialog is answered there.
      const onAbort = () => settle(null);
      this.held.set(prompt.id, { sessionId, prompt, settle });
      if (signal?.aborted) return settle(null);
      signal?.addEventListener("abort", onAbort, { once: true });
      this.onChange(sessionId, this.current(sessionId));
    });
  }

  /** Answers a held request; false when it is no longer held, or belongs to another session. */
  answer(sessionId: string, requestId: string, answer: PermissionAnswer): boolean {
    const held = this.held.get(requestId);
    if (!held || held.sessionId !== sessionId) return false;
    held.settle(answer);
    return true;
  }

  /** Lets go of a session's requests with no decision: it moved on, so they were answered in Claude. */
  release(sessionId: string) {
    for (const held of [...this.held.values()]) if (held.sessionId === sessionId) held.settle(null);
  }

  releaseAll() {
    for (const held of [...this.held.values()]) held.settle(null);
  }

  /** The request a session shows: its oldest held one. */
  current(sessionId: string): PermissionPrompt | null {
    for (const held of this.held.values()) if (held.sessionId === sessionId) return held.prompt;
    return null;
  }
}

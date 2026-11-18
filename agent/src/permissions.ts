/**
 * Permission prompts the strip can answer. Claude Code runs a PermissionRequest hook alongside its own
 * permission dialog, in a terminal as in the desktop app, and takes whichever answers first: the hook can hold
 * the request while the dialog shows, and answering on either side settles it. The agent holds each request
 * until the user answers it from the strip, answers it in Claude (the session's next event says so), or it
 * times out; a released request returns no decision, which leaves Claude's dialog in charge.
 *
 * Besides allow and deny, the strip can allow always, with the rule Claude itself suggests (the hook echoes it
 * back as `updatedPermissions`), and answer AskUserQuestion, whose answers Claude takes as `updatedInput`.
 *
 * Codex is left out: it runs the hook before it shows its own approval, so holding the request would hide it.
 */
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import type { PermissionPrompt, PromptQuestion } from "../../shared/protocol.ts";
import type { HookEvent } from "./state.ts";

/** An answer from the strip: allow (always, or with the chosen options of each question) or deny. */
export interface PermissionAnswer {
  allow: boolean;
  always?: boolean;
  /** For a prompt with questions: the index of each chosen option, per question, in order. */
  answers?: number[][];
}

/** What a settled request returns to Claude Code, and a word for the log. */
export interface Settled {
  output: { hookSpecificOutput: { hookEventName: "PermissionRequest"; decision: Record<string, unknown> } };
  said: "allow" | "always" | "deny" | "answered";
}

/** A plan's approval also picks the mode Claude goes on in, which the strip doesn't ask: it stays in Claude. */
const LEFT_TO_CLAUDE = new Set(["ExitPlanMode"]);
const QUESTION_TOOL = "AskUserQuestion";

/** Just under the hook's own timeout, so the agent answers before Claude gives up on the hook. */
export const HOLD_MS = 590_000;
const MAX_DETAIL = 4000;
const MAX_ALWAYS = 300;
const MAX_QUESTIONS = 8;
const MAX_OPTIONS = 8;

/** Whether the strip can answer this permission request. */
export function answerable(event: HookEvent): boolean {
  if (event.hook_event_name !== "PermissionRequest" || typeof event.tool_name !== "string") return false;
  if (LEFT_TO_CLAUDE.has(event.tool_name)) return false;
  return event.tool_name !== QUESTION_TOOL || questionsOf(event.tool_input) !== null;
}

/** AskUserQuestion's questions, or null when they aren't in the shape the strip can show. */
export function questionsOf(input: unknown): PromptQuestion[] | null {
  const raw = (input as { questions?: unknown } | null)?.questions;
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > MAX_QUESTIONS) return null;
  const questions: PromptQuestion[] = [];
  for (const q of raw as Record<string, unknown>[]) {
    if (typeof q?.question !== "string" || !q.question.trim() || !Array.isArray(q.options)) return null;
    if (q.options.length === 0 || q.options.length > MAX_OPTIONS) return null;
    const options: PromptQuestion["options"] = [];
    for (const o of q.options as Record<string, unknown>[]) {
      if (typeof o?.label !== "string" || !o.label.trim()) return null;
      options.push({ label: o.label, description: typeof o.description === "string" ? o.description : "" });
    }
    questions.push({ question: q.question, header: typeof q.header === "string" ? q.header : "", options, multiSelect: q.multiSelect === true });
  }
  return questions;
}

/** What the request asks to do, in full, for the user to read before answering: the command, file, URL or input. */
export function permissionDetail(tool: string, input: unknown): string {
  const i = (input ?? {}) as Record<string, unknown>;
  const str = (v: unknown) => (typeof v === "string" ? v.trim() : "");
  const questions = tool === QUESTION_TOOL ? questionsOf(input) : null;
  const detail =
    (questions ? questions.map((q) => q.question).join("\n") : "") ||
    str(i.command) ||
    str(i.file_path) ||
    str(i.notebook_path) ||
    str(i.url) ||
    str(i.query) ||
    str(i.pattern) ||
    (Object.keys(i).length > 0 ? JSON.stringify(i, null, 2) : tool);
  return clip(detail, MAX_DETAIL);
}

const WHERE: Record<string, string> = {
  session: "for this session",
  localSettings: "in this project",
  projectSettings: "in this project, for everyone",
  userSettings: "in every project",
};

/**
 * The "always allow" the strip offers: the first rule or folder Claude suggests allowing, with how it reads.
 * A mode change ("switch to auto mode") isn't offered: it allows far more than this one request.
 */
export function alwaysOffer(suggestions: unknown): { update: Record<string, unknown>; label: string } | null {
  if (!Array.isArray(suggestions)) return null;
  for (const update of suggestions as Record<string, unknown>[]) {
    const where = typeof update?.destination === "string" ? WHERE[update.destination] : undefined;
    if (!where) continue;
    if (update.type === "addRules" && update.behavior === "allow" && Array.isArray(update.rules) && update.rules.length > 0) {
      const rules = update.rules as Record<string, unknown>[];
      if (!rules.every((r) => typeof r?.toolName === "string" && (r.ruleContent === undefined || typeof r.ruleContent === "string"))) continue;
      const names = rules.map((r) => (r.ruleContent ? `${r.toolName}(${r.ruleContent})` : String(r.toolName)));
      return { update, label: clip(`${names.join(", ")} ${where}`, MAX_ALWAYS) };
    }
    if (update.type === "addDirectories" && Array.isArray(update.directories) && update.directories.length > 0) {
      const dirs = update.directories as unknown[];
      if (!dirs.every((d) => typeof d === "string")) continue;
      return { update, label: clip(`access to ${(dirs as string[]).map(tilde).join(", ")} ${where}`, MAX_ALWAYS) };
    }
  }
  return null;
}

interface Held {
  sessionId: string;
  prompt: PermissionPrompt;
  input: unknown;
  always: Record<string, unknown> | null;
  settle: (settled: Settled | null) => void;
}

/** The hook's output for an answer, or null when the answer doesn't fit the request. */
function decide(held: Held, answer: PermissionAnswer): Settled | null {
  const out = (decision: Record<string, unknown>, said: Settled["said"]): Settled => ({
    output: { hookSpecificOutput: { hookEventName: "PermissionRequest", decision } },
    said,
  });
  const { questions } = held.prompt;
  if (questions) {
    if (!answer.allow) return out({ behavior: "deny", message: "The user dismissed the question from Tomari." }, "deny");
    const chosen = answer.answers;
    if (answer.always || !chosen || chosen.length !== questions.length) return null;
    const answers: Record<string, string> = {};
    for (const [n, q] of questions.entries()) {
      const picks = chosen[n]!;
      if (picks.length === 0 || new Set(picks).size !== picks.length || (!q.multiSelect && picks.length > 1)) return null;
      if (picks.some((i) => i >= q.options.length)) return null;
      // Claude reads multiple choices as their labels joined with commas.
      answers[q.question] = picks.map((i) => q.options[i]!.label).join(", ");
    }
    return out({ behavior: "allow", updatedInput: { ...(held.input as object), answers } }, "answered");
  }
  if (answer.answers) return null;
  if (!answer.allow) return out({ behavior: "deny", message: "The user denied this from Tomari." }, "deny");
  if (!answer.always) return out({ behavior: "allow" }, "allow");
  return held.always ? out({ behavior: "allow", updatedPermissions: [held.always] }, "always") : null;
}

export class PermissionDesk {
  /** By request id, oldest first. */
  private held = new Map<string, Held>();

  constructor(
    /** Told the prompt a session now shows, or null when it has none left. */
    private onChange: (sessionId: string, prompt: PermissionPrompt | null) => void,
    private holdMs = HOLD_MS,
  ) {}

  /** Holds a request until it is answered or released: the hook's output, or null for no decision. */
  hold(event: HookEvent, signal?: AbortSignal): Promise<Settled | null> {
    const tool = String(event.tool_name ?? "");
    const prompt: PermissionPrompt = { id: randomUUID(), tool, detail: permissionDetail(tool, event.tool_input) };
    const questions = tool === QUESTION_TOOL ? questionsOf(event.tool_input) : null;
    const offer = questions ? null : alwaysOffer(event.permission_suggestions);
    if (questions) prompt.questions = questions;
    if (offer) prompt.always = offer.label;
    const sessionId = event.session_id;
    return new Promise((resolve) => {
      const timer = setTimeout(() => settle(null), this.holdMs);
      const settle = (settled: Settled | null) => {
        if (!this.held.delete(prompt.id)) return;
        clearTimeout(timer);
        signal?.removeEventListener("abort", onAbort);
        resolve(settled);
        this.onChange(sessionId, this.current(sessionId));
      };
      // Claude ends the hook once the dialog is answered there.
      const onAbort = () => settle(null);
      this.held.set(prompt.id, { sessionId, prompt, input: event.tool_input, always: offer?.update ?? null, settle });
      if (signal?.aborted) return settle(null);
      signal?.addEventListener("abort", onAbort, { once: true });
      this.onChange(sessionId, this.current(sessionId));
    });
  }

  /**
   * Answers a held request: "gone" when it is no longer held, or belongs to another session; "invalid" when the
   * answer doesn't fit it (always with nothing to add, or answers that aren't one choice per question).
   */
  answer(sessionId: string, requestId: string, answer: PermissionAnswer): "ok" | "gone" | "invalid" {
    const held = this.held.get(requestId);
    if (!held || held.sessionId !== sessionId) return "gone";
    const settled = decide(held, answer);
    if (!settled) return "invalid";
    held.settle(settled);
    return "ok";
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

function clip(text: string, max: number) {
  return text.length <= max ? text : `${text.slice(0, max - 1)}…`;
}

function tilde(path: string) {
  const home = homedir();
  return path === home || path.startsWith(`${home}/`) ? `~${path.slice(home.length)}` : path;
}

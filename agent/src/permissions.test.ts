import { expect, test } from "bun:test";
import type { PermissionPrompt } from "../../shared/protocol.ts";
import { homedir } from "node:os";
import { alwaysOffer, answerable, PermissionDesk, permissionDetail, type Settled } from "./permissions.ts";
import type { HookEvent } from "./state.ts";

const A = "0603472f-b7c5-4dae-b7a1-142468264b30";
const B = "22222222-2222-4222-8222-222222222222";
const request = (session_id: string, tool_name = "Bash", tool_input: unknown = { command: "rm -rf build", description: "Clean" }): HookEvent =>
  ({ hook_event_name: "PermissionRequest", session_id, cwd: "/tmp", tool_name, tool_input }) as HookEvent;

function desk(holdMs?: number) {
  const changes: [string, PermissionPrompt | null][] = [];
  return { changes, desk: new PermissionDesk((id, prompt) => changes.push([id, prompt]), holdMs) };
}

const QUESTION = {
  questions: [
    { question: "Which framework?", header: "Framework", options: [{ label: "React", description: "Components" }, { label: "Vue" }], multiSelect: false },
    { question: "Which extras?", header: "Extras", options: [{ label: "Tests", description: "" }, { label: "Lint", description: "" }, { label: "CI", description: "" }], multiSelect: true },
  ],
};
const RULE = { type: "addRules", rules: [{ toolName: "Bash", ruleContent: "npm test:*" }], behavior: "allow", destination: "localSettings" };
const withSuggestions = (permission_suggestions: unknown) => ({ ...request(A, "Bash", { command: "npm test" }), permission_suggestions }) as HookEvent;
const decision = (settled: Settled | null) => settled?.output.hookSpecificOutput.decision;

test("allow or deny, a question in the shape the strip shows, but never a plan, whose approval picks a mode", () => {
  expect(answerable(request(A))).toBe(true);
  expect(answerable(request(A, "mcp__github__create_issue"))).toBe(true);
  expect(answerable(request(A, "AskUserQuestion", QUESTION))).toBe(true);
  expect(answerable(request(A, "AskUserQuestion", { questions: [] }))).toBe(false);
  expect(answerable(request(A, "AskUserQuestion", { questions: [{ question: "Why?", options: [{ description: "no label" }] }] }))).toBe(false);
  expect(answerable(request(A, "ExitPlanMode"))).toBe(false);
  expect(answerable({ ...request(A), hook_event_name: "PreToolUse" } as HookEvent)).toBe(false);
});

test("the detail is the full command, file, URL, the questions, or else the input as JSON", () => {
  expect(permissionDetail("Bash", { command: "  git push --force\n", description: "Push" })).toBe("git push --force");
  expect(permissionDetail("Edit", { file_path: "/repo/a.ts", old_string: "x" })).toBe("/repo/a.ts");
  expect(permissionDetail("WebFetch", { url: "https://example.com", prompt: "read" })).toBe("https://example.com");
  expect(permissionDetail("AskUserQuestion", QUESTION)).toBe("Which framework?\nWhich extras?");
  expect(permissionDetail("mcp__x__y", { a: 1 })).toBe('{\n  "a": 1\n}');
  expect(permissionDetail("Tool", {})).toBe("Tool");
  expect(permissionDetail("Bash", { command: "x".repeat(5000) }).length).toBe(4000);
});

test("always offers the first rule or folder Claude suggests, never a mode change, and says where it applies", () => {
  expect(alwaysOffer([RULE])).toEqual({ update: RULE, label: "Bash(npm test:*) in this project" });
  const mode = { type: "setMode", mode: "acceptEdits", destination: "session" };
  const dirs = { type: "addDirectories", directories: [`${homedir()}/code/app`], destination: "session" };
  expect(alwaysOffer([mode, dirs])?.label).toBe("access to ~/code/app for this session");
  expect(alwaysOffer([{ ...RULE, rules: [{ toolName: "mcp__github__get_issue" }], destination: "userSettings" }])?.label).toBe("mcp__github__get_issue in every project");
  expect(alwaysOffer([mode])).toBeNull();
  expect(alwaysOffer([{ ...RULE, behavior: "deny" }])).toBeNull();
  expect(alwaysOffer([{ ...RULE, destination: "cliArg" }])).toBeNull();
  expect(alwaysOffer(undefined)).toBeNull();
});

test("a held request shows on its session and settles with the answer, once", async () => {
  const { desk: d, changes } = desk();
  const held = d.hold(request(A));
  const prompt = d.current(A)!;
  expect(prompt).toMatchObject({ tool: "Bash", detail: "rm -rf build" });
  expect(prompt.always).toBeUndefined();
  expect(changes).toEqual([[A, prompt]]);

  expect(d.answer(B, prompt.id, { allow: true })).toBe("gone"); // another session's id
  expect(d.answer(A, prompt.id, { allow: true, always: true })).toBe("invalid"); // Claude suggested no rule
  expect(d.answer(A, prompt.id, { allow: true })).toBe("ok");
  expect(await held).toEqual({ output: { hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow" } } }, said: "allow" });
  expect(d.answer(A, prompt.id, { allow: false })).toBe("gone");
  expect(changes.at(-1)).toEqual([A, null]);
});

test("a denial tells Claude it came from Tomari", async () => {
  const { desk: d } = desk();
  const held = d.hold(request(A));
  d.answer(A, d.current(A)!.id, { allow: false });
  expect(decision(await held)).toEqual({ behavior: "deny", message: expect.stringContaining("Tomari") });
});

test("always allows with the rule Claude suggested, echoed back as it came", async () => {
  const { desk: d } = desk();
  const held = d.hold(withSuggestions([RULE]));
  const prompt = d.current(A)!;
  expect(prompt.always).toBe("Bash(npm test:*) in this project");
  expect(d.answer(A, prompt.id, { allow: true, always: true })).toBe("ok");
  const settled = await held;
  expect(settled?.said).toBe("always");
  expect(decision(settled)).toEqual({ behavior: "allow", updatedPermissions: [RULE] });
});

test("a question is answered with one option per question, several where multiSelect, as Claude reads answers", async () => {
  const { desk: d } = desk();
  const held = d.hold(request(A, "AskUserQuestion", QUESTION));
  const prompt = d.current(A)!;
  expect(prompt.questions?.map((q) => [q.header, q.options.map((o) => o.label), q.multiSelect])).toEqual([
    ["Framework", ["React", "Vue"], false],
    ["Extras", ["Tests", "Lint", "CI"], true],
  ]);
  expect(prompt.questions?.[0]?.options[1]?.description).toBe("");
  expect(prompt.always).toBeUndefined();

  for (const bad of [{ allow: true }, { allow: true, answers: [[0]] }, { allow: true, answers: [[0, 1], [0]] }, { allow: true, answers: [[2], [0]] }, { allow: true, answers: [[0], []] }, { allow: true, answers: [[0], [1, 1]] }, { allow: true, always: true, answers: [[0], [0]] }]) {
    expect(d.answer(A, prompt.id, bad)).toBe("invalid");
  }
  expect(d.answer(A, prompt.id, { allow: true, answers: [[1], [2, 0]] })).toBe("ok");
  expect(decision(await held)).toEqual({
    behavior: "allow",
    updatedInput: { ...QUESTION, answers: { "Which framework?": "Vue", "Which extras?": "CI, Tests" } },
  });
});

test("answers don't fit a plain permission request", () => {
  const { desk: d } = desk();
  d.hold(request(A));
  expect(d.answer(A, d.current(A)!.id, { allow: true, answers: [[0]] })).toBe("invalid");
  d.releaseAll();
});

test("a session moving on, the hook ending, or the timeout releases a request with no decision", async () => {
  const { desk: d } = desk(30);
  const first = d.hold(request(A));
  const second = d.hold(request(A, "Write", { file_path: "/a" }));
  const other = d.hold(request(B));
  expect(d.current(A)?.tool).toBe("Bash"); // the oldest first
  d.release(A);
  expect(await first).toBeNull();
  expect(await second).toBeNull();
  expect(d.current(A)).toBeNull();
  expect(d.current(B)).not.toBeNull();

  const aborts = new AbortController();
  const aborted = d.hold(request(A), aborts.signal);
  aborts.abort();
  expect(await aborted).toBeNull();

  expect(await other).toBeNull(); // timed out
});

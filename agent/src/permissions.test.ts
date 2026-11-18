import { expect, test } from "bun:test";
import type { PermissionPrompt } from "../../shared/protocol.ts";
import { answerable, decisionOutput, PermissionDesk, permissionDetail } from "./permissions.ts";
import type { HookEvent } from "./state.ts";

const A = "0603472f-b7c5-4dae-b7a1-142468264b30";
const B = "22222222-2222-4222-8222-222222222222";
const request = (session_id: string, tool_name = "Bash", tool_input: unknown = { command: "rm -rf build", description: "Clean" }): HookEvent =>
  ({ hook_event_name: "PermissionRequest", session_id, cwd: "/tmp", tool_name, tool_input }) as HookEvent;

function desk(holdMs?: number) {
  const changes: [string, PermissionPrompt | null][] = [];
  return { changes, desk: new PermissionDesk((id, prompt) => changes.push([id, prompt]), holdMs) };
}

test("only a plain allow or deny is answerable: not a question or a plan, which need an answer as input", () => {
  expect(answerable(request(A))).toBe(true);
  expect(answerable(request(A, "mcp__github__create_issue"))).toBe(true);
  expect(answerable(request(A, "AskUserQuestion"))).toBe(false);
  expect(answerable(request(A, "ExitPlanMode"))).toBe(false);
  expect(answerable({ ...request(A), hook_event_name: "PreToolUse" } as HookEvent)).toBe(false);
});

test("the detail is the full command, file, URL, or else the input as JSON", () => {
  expect(permissionDetail("Bash", { command: "  git push --force\n", description: "Push" })).toBe("git push --force");
  expect(permissionDetail("Edit", { file_path: "/repo/a.ts", old_string: "x" })).toBe("/repo/a.ts");
  expect(permissionDetail("WebFetch", { url: "https://example.com", prompt: "read" })).toBe("https://example.com");
  expect(permissionDetail("mcp__x__y", { a: 1 })).toBe('{\n  "a": 1\n}');
  expect(permissionDetail("Tool", {})).toBe("Tool");
  expect(permissionDetail("Bash", { command: "x".repeat(5000) }).length).toBe(4000);
});

test("the decision is the hook output Claude Code reads", () => {
  expect(decisionOutput("allow")).toEqual({ hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow" } } });
  expect(decisionOutput("deny").hookSpecificOutput.decision).toMatchObject({ behavior: "deny", message: expect.any(String) });
});

test("a held request shows on its session and settles with the answer, once", async () => {
  const { desk: d, changes } = desk();
  const held = d.hold(request(A));
  const prompt = d.current(A)!;
  expect(prompt).toMatchObject({ tool: "Bash", detail: "rm -rf build" });
  expect(changes).toEqual([[A, prompt]]);

  expect(d.answer(B, prompt.id, "allow")).toBe(false); // another session's id
  expect(d.answer(A, prompt.id, "allow")).toBe(true);
  expect(await held).toBe("allow");
  expect(d.answer(A, prompt.id, "deny")).toBe(false);
  expect(changes.at(-1)).toEqual([A, null]);
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

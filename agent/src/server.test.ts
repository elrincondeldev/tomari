import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import type { ServerMessage } from "../../shared/protocol.ts";
import type { DesktopSession } from "./desktop-sessions.ts";
import { FrontApp } from "./front-app.ts";
import { SessionHub } from "./hub.ts";
import { planOpen, type OpenResult } from "./open-session.ts";
import { openLogLine, startServers } from "./server.ts";
import type { CodexThread } from "./codex.ts";
import { Store } from "./store.ts";

const ID = "0603472f-b7c5-4dae-b7a1-142468264b30";
const TOKEN = "test-token";

const IDLE = "22222222-2222-4222-8222-222222222222";
const DESKTOP: DesktopSession[] = [
  { localId: "local_idle", sessionId: IDLE, title: "Idle work", cwd: "/Users/dev/idle", lastActivityAt: 5000, archived: false },
  { localId: "local_old", sessionId: "33333333-3333-4333-8333-333333333333", title: "Old", cwd: "/x", lastActivityAt: 1, archived: true },
];

let servers: ReturnType<typeof startServers>;
let hub: SessionHub;
let front: FrontApp;
let opened: [id: string, cwd: string | undefined, kind: string | undefined, name: string | undefined][];
let stopped: string[];
let stop: (id: string) => Promise<OpenResult>;
let desktopSessions: () => Promise<DesktopSession[]>;
let terminal: () => Promise<OpenResult>;
let codexLibrary: () => Promise<CodexThread[]>;
let started: [cwd: string, agent: string][];

beforeEach(() => {
  opened = [];
  stopped = [];
  started = [];
  stop = async (id) => {
    stopped.push(id);
    return { ok: true, command: ["fake-stop", id] };
  };
  hub = new SessionHub(new Store());
  front = new FrontApp();
  desktopSessions = async () => DESKTOP;
  terminal = async () => ({ ok: true, command: ["fake-terminal"] });
  codexLibrary = async () => [];
  servers = startServers({
    hub,
    front,
    token: TOKEN,
    hookPort: 0, // 0 = any free port
    panelPort: 0,
    open: async (id, { cwd, kind, name } = {}) => {
      opened.push([id, cwd, kind, name]);
      return { ok: true, command: ["fake-open", id] };
    },
    desktopSessions: () => desktopSessions(),
    terminal: () => terminal(),
    stop: (id) => stop(id),
    codexPid: async (reported) => (reported === 4242 ? 4200 : null),
    admitCodex: async (event) => event.hook_event_name !== "SessionStart",
    codexLibrary: () => codexLibrary(),
    newSession: async (cwd, agent) => {
      started.push([cwd, agent]);
      return { ok: true, command: ["fake-new", cwd, agent] };
    },
  });
});
afterEach(() => servers.stop());

const hookUrl = () => `http://127.0.0.1:${servers.hookServer.port}/hook`;
const panelHttp = () => `http://127.0.0.1:${servers.panelServer.port}`;

function postHook(event: Record<string, unknown>, url = hookUrl()) {
  return fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(event) });
}

/** Opens a panel connection; next() resolves with the following server message. */
async function connect(token = TOKEN) {
  const ws = new WebSocket(`ws://127.0.0.1:${servers.panelServer.port}/ws?token=${token}`);
  const inbox: ServerMessage[] = [];
  const waiting: ((m: ServerMessage) => void)[] = [];
  ws.onmessage = (e) => {
    const msg = JSON.parse(String(e.data)) as ServerMessage;
    const resolve = waiting.shift();
    if (resolve) resolve(msg);
    else inbox.push(msg);
  };
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = reject;
  });
  const next = () =>
    inbox.length > 0 ? Promise.resolve(inbox.shift()!) : new Promise<ServerMessage>((resolve) => waiting.push(resolve));
  return { ws, next };
}

async function waitFor(condition: () => boolean, timeoutMs = 1000) {
  const start = Date.now();
  while (!condition()) {
    if (Date.now() - start > timeoutMs) throw new Error("timed out");
    await Bun.sleep(5);
  }
}

test("a wrong token is rejected", async () => {
  expect((await fetch(`${panelHttp()}/ws?token=nope`)).status).toBe(401);
  expect((await fetch(`${panelHttp()}/ws`)).status).toBe(401);
});

test("the network-facing port does not accept hook events", async () => {
  const res = await postHook({ hook_event_name: "Stop", session_id: ID, cwd: "/tmp" }, `${panelHttp()}/hook`);
  expect(res.status).toBe(404);
});

test("the panel gets a snapshot, then live updates from hooks", async () => {
  const { ws, next } = await connect();
  expect(await next()).toEqual({ type: "snapshot", sessions: [], focusedId: null });

  const res = await postHook({ hook_event_name: "UserPromptSubmit", session_id: ID, cwd: "/tmp/demo" });
  expect(res.status).toBe(204);
  expect(await next()).toMatchObject({ type: "session", session: { id: ID, name: "demo", state: "working", live: true } });
  ws.close();
});

test("pin, icon and open commands; anything else is refused", async () => {
  await postHook({ hook_event_name: "Stop", session_id: ID, cwd: "/tmp/demo" });
  const { ws, next } = await connect();
  await next(); // snapshot

  ws.send(JSON.stringify({ type: "pin", id: ID, pinned: true }));
  expect(await next()).toMatchObject({ type: "session", session: { id: ID, pinned: true, position: 0 } });

  ws.send(JSON.stringify({ type: "pin", id: ID, pinned: false }));
  expect(await next()).toMatchObject({ type: "session", session: { pinned: false } });

  ws.send(JSON.stringify({ type: "icon", id: ID, icon: { character: "crab", color: "#ff6a1a" } }));
  expect(await next()).toMatchObject({ type: "session", session: { pinned: true, icon: { character: "crab" } } });

  ws.send(JSON.stringify({ type: "open", id: ID }));
  await waitFor(() => opened.length === 1);
  expect(opened).toEqual([[ID, "/tmp/demo", undefined, undefined]]); // where it last ran, for resuming it in a terminal
  expect(await next()).toEqual({ type: "focus", id: ID });

  ws.send(JSON.stringify({ type: "open", id: "11111111-1111-1111-1111-111111111111" }));
  expect(await next()).toEqual({ type: "error", message: "unknown session" });

  ws.send("rm -rf /");
  expect(await next()).toEqual({ type: "error", message: "invalid message" });
  ws.close();
});

test("the library lists desktop sessions, and pinning one that isn't running adopts it", async () => {
  const { ws, next } = await connect();
  await next(); // snapshot

  ws.send(JSON.stringify({ type: "library" }));
  expect(await next()).toEqual({
    type: "library",
    sessions: [{ id: IDLE, name: "Idle work", cwd: "/Users/dev/idle", lastActivityAt: 5000, pinned: false }],
  });

  ws.send(JSON.stringify({ type: "pin", id: IDLE, pinned: true }));
  expect(await next()).toMatchObject({ type: "session", session: { id: IDLE, name: "Idle work", live: false, state: "ended" } });
  expect(await next()).toMatchObject({ type: "session", session: { id: IDLE, pinned: true } });

  ws.send(JSON.stringify({ type: "library" }));
  expect(await next()).toMatchObject({ type: "library", sessions: [{ id: IDLE, pinned: true }] });
  ws.close();
});

test("opening a library session the agent never saw, from the launcher, adopts it unpinned and opens it", async () => {
  const { ws, next } = await connect();
  await next(); // snapshot

  ws.send(JSON.stringify({ type: "open", id: IDLE }));
  expect(await next()).toMatchObject({ type: "session", session: { id: IDLE, name: "Idle work", pinned: false, live: false } });
  await waitFor(() => opened.length === 1);
  expect(opened).toEqual([[IDLE, "/Users/dev/idle", undefined, "Idle work"]]);
  ws.close();
});

test("the library also lists live terminal sessions, newest first; the desktop entry wins a duplicate", async () => {
  const NEWER = { ...DESKTOP[0]!, localId: "local_newer", sessionId: "44444444-4444-4444-8444-444444444444", title: "Newer", lastActivityAt: Date.now() + 60_000 };
  desktopSessions = async () => [NEWER, ...DESKTOP];
  const GONE = "55555555-5555-4555-8555-555555555555";
  await postHook({ hook_event_name: "UserPromptSubmit", session_id: ID, cwd: "/tmp/demo" });
  await postHook({ hook_event_name: "UserPromptSubmit", session_id: IDLE, cwd: "/tmp/elsewhere" }); // also in the desktop list
  await postHook({ hook_event_name: "UserPromptSubmit", session_id: GONE, cwd: "/tmp/gone" });
  await postHook({ hook_event_name: "SessionEnd", session_id: GONE, cwd: "/tmp/gone", reason: "other" });
  const { ws, next } = await connect();
  await next(); // snapshot

  ws.send(JSON.stringify({ type: "library" }));
  expect(await next()).toEqual({
    type: "library",
    sessions: [
      { id: NEWER.sessionId, name: "Newer", cwd: "/Users/dev/idle", lastActivityAt: NEWER.lastActivityAt, pinned: false },
      { id: ID, name: "demo", cwd: "/tmp/demo", lastActivityAt: expect.any(Number), pinned: false },
      { id: IDLE, name: "Idle work", cwd: "/Users/dev/idle", lastActivityAt: 5000, pinned: false },
    ],
  });
  ws.close();
});

test("a terminal session from the library can be pinned", async () => {
  await postHook({ hook_event_name: "Stop", session_id: ID, cwd: "/tmp/demo" });
  const { ws, next } = await connect();
  await next(); // snapshot

  ws.send(JSON.stringify({ type: "pin", id: ID, pinned: true }));
  expect(await next()).toMatchObject({ type: "session", session: { id: ID, pinned: true } });
  ws.send(JSON.stringify({ type: "library" }));
  expect(await next()).toMatchObject({ type: "library", sessions: [{ id: ID, pinned: true }, { id: IDLE }] });
  ws.close();
});

test("terminal opens a new Terminal tab; a failure comes back as an error", async () => {
  let opens = 0;
  terminal = async () => {
    opens++;
    return { ok: true, command: ["fake-terminal"] };
  };
  const { ws, next } = await connect();
  await next(); // snapshot

  ws.send(JSON.stringify({ type: "terminal" }));
  await waitFor(() => opens === 1);

  terminal = async () => ({ ok: false, error: "osascript exited with 1: not allowed" });
  ws.send(JSON.stringify({ type: "terminal" }));
  expect(await next()).toEqual({ type: "error", message: "osascript exited with 1: not allowed" });
  ws.close();
});

test("a message that fails is answered with an error, and the server keeps serving", async () => {
  const { ws, next } = await connect();
  await next(); // snapshot

  desktopSessions = async () => {
    throw new Error("disk on fire");
  };
  ws.send(JSON.stringify({ type: "library" }));
  expect(await next()).toEqual({ type: "error", message: "internal error" });

  desktopSessions = async () => DESKTOP;
  ws.send(JSON.stringify({ type: "library" }));
  expect(await next()).toMatchObject({ type: "library", sessions: [{ id: IDLE }] });
  ws.close();
});

test("planOpen: deep link for desktop sessions (running or not), refuse terminal ones, --resume otherwise", async () => {
  const root = mkdtempSync(`${tmpdir()}/claude-open-`);
  const liveDir = `${root}/live`;
  const desktopDir = `${root}/desktop`;
  mkdirSync(liveDir);
  mkdirSync(`${desktopDir}/account/org`, { recursive: true });
  const dirs = { liveDir, desktopDir, ttyOf: async () => undefined }; // no tty: a real one would focus a tab
  try {
    expect(await planOpen("not-a-uuid", dirs)).toEqual({ ok: false, error: "invalid session id" });

    const unknown = await planOpen(ID, dirs);
    expect(unknown.ok && unknown.command.slice(1)).toEqual(["--desktop", "--resume", ID]);

    // process.pid makes the fake session count as running.
    writeFileSync(`${liveDir}/1.json`, JSON.stringify({ pid: process.pid, sessionId: ID, entrypoint: "cli" }));
    expect((await planOpen(ID, dirs)).ok).toBe(false);

    // Known to the desktop app: its link wins, whether or not a process runs.
    writeFileSync(`${desktopDir}/account/org/local_abc-123.json`, JSON.stringify({ sessionId: "local_abc-123", cliSessionId: ID }));
    expect(await planOpen(ID, dirs)).toEqual({ ok: true, command: ["open", "claude://code/continue?session=local_abc-123"] });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

const BG = "4c3f6979-6d4f-4add-8de8-b71ea72d0f6e";

test("opening a background session tells the opener its kind", async () => {
  hub.handleAgents([{ sessionId: BG, cwd: "/tmp/bg", kind: "background", status: "idle", startedAt: 0 }]);
  const { ws, next } = await connect();
  await next(); // snapshot
  ws.send(JSON.stringify({ type: "open", id: BG }));
  await waitFor(() => opened.length === 1);
  expect(opened).toEqual([[BG, "/tmp/bg", "background", undefined]]);
  ws.close();
});

test("opening passes the session's real title, not the label the panel shows", async () => {
  const OTHER = "9a8b7c6d-1111-4222-8333-444455556666";
  // Two untitled sessions in one folder: both get a label of folder and prompt, but neither has a title.
  await postHook({ hook_event_name: "UserPromptSubmit", session_id: ID, cwd: "/tmp/demo", prompt: "first thing" });
  await postHook({ hook_event_name: "UserPromptSubmit", session_id: OTHER, cwd: "/tmp/demo", prompt: "second thing" });
  hub.handleAgents([{ sessionId: BG, name: "Release work", cwd: "/tmp/bg", kind: "background", status: "idle", startedAt: 0 }]);
  expect(hub.get(ID)!.name).toBe("demo · first thing");
  const { ws, next } = await connect();
  await next(); // snapshot
  for (const id of [ID, BG]) ws.send(JSON.stringify({ type: "open", id }));
  await waitFor(() => opened.length === 2);
  expect(opened.map(([id, , , name]) => [id, name])).toEqual([
    [ID, undefined],
    [BG, "Release work"],
  ]);
  ws.close();
});

test("stop ends a live background session right away", async () => {
  hub.handleAgents([{ sessionId: BG, cwd: "/tmp/bg", kind: "background", status: "busy", startedAt: 0 }]);
  const { ws, next } = await connect();
  await next(); // snapshot
  ws.send(JSON.stringify({ type: "stop", id: BG }));
  expect(await next()).toMatchObject({ type: "session", session: { id: BG, state: "ended", live: false } });
  expect(stopped).toEqual([BG]);
  ws.close();
});

test("stop refuses interactive, closed and unknown sessions without running anything", async () => {
  await postHook({ hook_event_name: "Stop", session_id: ID, cwd: "/tmp/demo" }); // kind unknown
  hub.handleAgents([{ sessionId: BG, cwd: "/tmp/bg", kind: "background", status: "idle", startedAt: 0 }]);
  hub.endSession(BG);
  const { ws, next } = await connect();
  await next(); // snapshot
  for (const id of [ID, BG]) {
    ws.send(JSON.stringify({ type: "stop", id }));
    expect(await next()).toEqual({ type: "error", message: "not a running background session" });
  }
  ws.send(JSON.stringify({ type: "stop", id: IDLE })); // a desktop session: must not even be adopted
  expect(await next()).toEqual({ type: "error", message: "unknown session" });
  expect(stopped).toEqual([]);
  ws.close();
});

test("a failed stop reaches the panel and leaves the session alone", async () => {
  hub.handleAgents([{ sessionId: BG, cwd: "/tmp/bg", kind: "background", status: "idle", startedAt: 0 }]);
  stop = async () => ({ ok: false, error: "claude exited with 1" });
  const { ws, next } = await connect();
  await next(); // snapshot
  ws.send(JSON.stringify({ type: "stop", id: BG }));
  expect(await next()).toEqual({ type: "error", message: "claude exited with 1" });
  expect(hub.get(BG)!.live).toBe(true);
  ws.close();
});

test("a second stop while the first is still running is ignored, and the id can be stopped again afterwards", async () => {
  hub.handleAgents([{ sessionId: BG, cwd: "/tmp/bg", kind: "background", status: "busy", startedAt: 0 }]);
  let finish!: (r: OpenResult) => void;
  stop = (id) => {
    stopped.push(id);
    return new Promise((resolve) => (finish = resolve));
  };
  const { ws, next } = await connect();
  await next(); // snapshot
  ws.send(JSON.stringify({ type: "stop", id: BG }));
  await waitFor(() => stopped.length === 1);
  ws.send(JSON.stringify({ type: "stop", id: BG }));
  expect(await next()).toEqual({ type: "error", message: "already stopping" });
  expect(stopped).toEqual([BG]);
  finish({ ok: false, error: "claude exited with 1" });
  expect(await next()).toEqual({ type: "error", message: "claude exited with 1" });
  ws.send(JSON.stringify({ type: "stop", id: BG })); // the guard was released
  await waitFor(() => stopped.length === 2);
  finish({ ok: true, command: ["fake-stop", BG] });
  ws.close();
});

test("a client reports the front app, and it is unknown again once that client leaves", async () => {
  const { ws, next } = await connect();
  await next(); // snapshot
  expect(front.value).toBe("unknown");
  ws.send(JSON.stringify({ type: "frontApp", app: "terminal" }));
  await waitFor(() => front.value === "terminal");
  ws.send(JSON.stringify({ type: "frontApp", app: "other" }));
  await waitFor(() => front.value === "other");
  ws.close();
  await waitFor(() => front.value === "unknown");
});

test("a client that never reported leaves the front app alone when it disconnects", async () => {
  const reporter = await connect();
  await reporter.next();
  reporter.ws.send(JSON.stringify({ type: "frontApp", app: "desktop" }));
  await waitFor(() => front.value === "desktop");
  const viewer = await connect(); // a second client that only watches
  await viewer.next();
  viewer.ws.close();
  await Bun.sleep(50);
  expect(front.value).toBe("desktop");
  reporter.ws.close();
});

test("openLogLine: how long an open took, and when it went through needs-input", () => {
  const id = "0123456789abcdef";
  expect(openLogLine(id, { ok: true, command: ["open", "x"] }, 84)).toBe("open 01234567: ok · 84ms");
  expect(openLogLine(id, { ok: true, command: ["open", "x"], before: ["open", "y"] }, 612)).toBe("open 01234567: ok via needs-input · 612ms");
  expect(openLogLine(id, { ok: false, error: "timed out" }, 15000)).toBe("open 01234567: timed out · 15000ms");
});

test("opening the session the desktop app counts as focused, with the app in front, asks for the detour", async () => {
  let focused: string | null = ID;
  const seen: (boolean | undefined)[] = [];
  servers.stop();
  servers = startServers({
    hub,
    front,
    token: TOKEN,
    hookPort: 0,
    panelPort: 0,
    open: async (id, options = {}) => (seen.push(options.focusedInDesktop), { ok: true, command: ["fake-open", id] }),
    desktopSessions: async () => DESKTOP,
    codexLibrary: async () => [],
    desktopFocus: () => focused,
  });
  await postHook({ hook_event_name: "Stop", session_id: ID, cwd: "/tmp/demo" });
  const { ws, next } = await connect();
  await next(); // snapshot
  const openIt = async () => {
    ws.send(JSON.stringify({ type: "open", id: ID }));
    while (seen.length < count + 1) await Bun.sleep(2);
    count++;
  };
  let count = 0;
  front.set("desktop");
  await openIt(); // focused there, app in front: detour
  front.set("other");
  await openIt(); // app behind: a plain link brings it forward
  front.set("desktop");
  focused = IDLE;
  await openIt(); // another session focused there: plain link
  expect(seen).toEqual([true, false, false]);
  ws.close();
});

test("openLogLine: one line per open request, without paths", () => {
  const id = "0123456789abcdef";
  expect(openLogLine(id, { ok: true, command: ["open", "claude://x"] })).toBe("open 01234567: ok");
  expect(openLogLine(id, { ok: false, error: "no Terminal tab on /dev/ttys004\nat line 2" })).toBe(
    "open 01234567: no Terminal tab on <path>",
  );
  expect(openLogLine(id, { ok: false, error: "cd: /Users/someone/Projects/demo: not found" })).toBe(
    "open 01234567: cd: <path> not found",
  );
  expect(openLogLine(id, { ok: false, error: "x".repeat(300) })).toBe(`open 01234567: ${"x".repeat(120)}`);
  expect(openLogLine(id, { ok: false, error: "" })).toBe("open 01234567: ");
});

test("Codex hooks arrive on their own path, with the Codex process behind them", async () => {
  const post = (pid: string) =>
    fetch(`${hookUrl()}/codex`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Tomari-Pid": pid },
      body: JSON.stringify({ hook_event_name: "PermissionRequest", session_id: ID, cwd: "/tmp/demo", tool_name: "Bash", tool_input: { command: "ls" } }),
    });
  expect((await post("4242")).status).toBe(204);
  expect(hub.get(ID)).toMatchObject({ agent: "codex", state: "needs_permission" });
  expect(hub.openContext(ID).pid).toBe(4200);
  // A pid that leads to no Codex process, or no pid at all, keeps the one known.
  await post("77");
  await post("not a pid");
  expect(hub.openContext(ID).pid).toBe(4200);
  expect((await fetch(`${hookUrl()}/other`, { method: "POST", body: "{}" })).status).toBe(404);
});

test("a Codex session the admission turns down never reaches the hub", async () => {
  const res = await fetch(`${hookUrl()}/codex`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ hook_event_name: "SessionStart", session_id: ID, cwd: "/tmp/demo", source: "startup" }),
  });
  expect(res.status).toBe(204);
  expect(hub.has(ID)).toBe(false);
});

test("the library lists Codex threads as Codex's, and pinning a closed one adopts it as Codex's", async () => {
  const THREAD = "01a1eb1b-0000-7000-8000-000000000001";
  codexLibrary = async () => [{ id: THREAD, name: "Orientar ruta", cwd: "/Users/dev/shy-planner", lastActivityAt: 9000 }];
  const { ws, next } = await connect();
  await next(); // snapshot

  ws.send(JSON.stringify({ type: "library" }));
  expect(await next()).toEqual({
    type: "library",
    sessions: [
      { id: THREAD, name: "Orientar ruta", cwd: "/Users/dev/shy-planner", lastActivityAt: 9000, pinned: false, agent: "codex" },
      { id: IDLE, name: "Idle work", cwd: "/Users/dev/idle", lastActivityAt: 5000, pinned: false },
    ],
  });

  ws.send(JSON.stringify({ type: "pin", id: THREAD, pinned: true }));
  expect(await next()).toMatchObject({ type: "session", session: { id: THREAD, agent: "codex", live: false, state: "ended" } });
  expect(await next()).toMatchObject({ type: "session", session: { id: THREAD, pinned: true, icon: { character: "robot" } } });
  ws.close();
});

test("the library keeps up to 100 sessions per agent, so many of one never crowd out the other", async () => {
  codexLibrary = async () =>
    Array.from({ length: 120 }, (_, i) => ({ id: `01a1eb1b-0000-7000-8000-${String(i).padStart(12, "0")}`, name: `t${i}`, cwd: "/x", lastActivityAt: 10_000 + i }));
  const { ws, next } = await connect();
  await next(); // snapshot
  ws.send(JSON.stringify({ type: "library" }));
  const reply = (await next()) as Extract<ServerMessage, { type: "library" }>;
  expect(reply.sessions.filter((s) => s.agent === "codex").length).toBe(100);
  expect(reply.sessions.some((s) => s.id === IDLE)).toBe(true); // the older Claude session is still there
  ws.close();
});

const permissionUrl = () => `${hookUrl()}/permission`;
const PERMISSION = { hook_event_name: "PermissionRequest", session_id: ID, cwd: "/tmp/demo", tool_name: "Bash", tool_input: { command: "git push", description: "Push" } };

/** The next session message for ID whose permission is present (`true`) or absent (`false`). */
async function permissionChange(next: () => Promise<ServerMessage>, present: boolean) {
  for (;;) {
    const msg = await next();
    if (msg.type === "session" && msg.session.id === ID && (msg.session.permission !== undefined) === present) return msg.session;
  }
}

test("with no panel connected, a permission request gets no decision at once", async () => {
  const res = await postHook(PERMISSION, permissionUrl());
  expect(res.status).toBe(204);
  expect(hub.has(ID)).toBe(false);
});

test("a permission request waits on the strip, and its answer is the hook's decision", async () => {
  const { ws, next } = await connect();
  await next(); // snapshot
  const pending = postHook(PERMISSION, permissionUrl());
  const session = await permissionChange(next, true);
  expect(session).toMatchObject({ state: "needs_permission", permission: { tool: "Bash", detail: "git push" } });

  ws.send(JSON.stringify({ type: "permission", id: ID, request: session.permission!.id, allow: true }));
  const res = await pending;
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow" } } });
  await permissionChange(next, false);

  ws.send(JSON.stringify({ type: "permission", id: ID, request: session.permission!.id, allow: false }));
  expect(await next()).toEqual({ type: "error", message: "already answered" });
  ws.close();
});

test("a denial is the hook's decision too", async () => {
  const { ws, next } = await connect();
  await next(); // snapshot
  const pending = postHook(PERMISSION, permissionUrl());
  const session = await permissionChange(next, true);
  ws.send(JSON.stringify({ type: "permission", id: ID, request: session.permission!.id, allow: false }));
  expect(await (await pending).json()).toMatchObject({ hookSpecificOutput: { decision: { behavior: "deny" } } });
  ws.close();
});

test("a request answered in Claude, the session moving on, lets the hook go with no decision", async () => {
  const { ws, next } = await connect();
  await next(); // snapshot
  const pending = postHook(PERMISSION, permissionUrl());
  await permissionChange(next, true);
  await postHook({ hook_event_name: "Notification", session_id: ID, cwd: "/tmp/demo", notification_type: "permission_prompt" });
  await postHook({ hook_event_name: "PostToolUse", session_id: ID, cwd: "/tmp/demo", tool_name: "Bash", tool_input: { command: "git push" } });
  expect((await pending).status).toBe(204);
  await permissionChange(next, false);
  ws.close();
});

test("a plan is never held: approving it also picks a mode, which stays in Claude", async () => {
  const { ws, next } = await connect();
  await next(); // snapshot
  const res = await postHook({ ...PERMISSION, tool_name: "ExitPlanMode", tool_input: { plan: "# Plan" } }, permissionUrl());
  expect(res.status).toBe(204);
  ws.close();
});

test("a question waits on the strip as needs input, and the chosen options are the hook's answers", async () => {
  const { ws, next } = await connect();
  await next(); // snapshot
  const input = { questions: [{ question: "Which color?", header: "Color", options: [{ label: "Red", description: "" }, { label: "Blue", description: "" }], multiSelect: false }] };
  const pending = postHook({ ...PERMISSION, tool_name: "AskUserQuestion", tool_input: input }, permissionUrl());
  const session = await permissionChange(next, true);
  expect(session).toMatchObject({ state: "needs_input", permission: { tool: "AskUserQuestion", questions: [{ question: "Which color?" }] } });

  ws.send(JSON.stringify({ type: "permission", id: ID, request: session.permission!.id, allow: true, answers: [[5]] }));
  expect(await next()).toEqual({ type: "error", message: "invalid answer" });
  ws.send(JSON.stringify({ type: "permission", id: ID, request: session.permission!.id, allow: true, answers: [[1]] }));
  expect(await (await pending).json()).toEqual({
    hookSpecificOutput: { hookEventName: "PermissionRequest", decision: { behavior: "allow", updatedInput: { ...input, answers: { "Which color?": "Blue" } } } },
  });
  ws.close();
});

test("always allow answers with the rule Claude suggested", async () => {
  const { ws, next } = await connect();
  await next(); // snapshot
  const rule = { type: "addRules", rules: [{ toolName: "Bash", ruleContent: "git push" }], behavior: "allow", destination: "localSettings" };
  const pending = postHook({ ...PERMISSION, permission_suggestions: [rule] }, permissionUrl());
  const session = await permissionChange(next, true);
  expect(session.permission?.always).toBe("Bash(git push) in this project");
  ws.send(JSON.stringify({ type: "permission", id: ID, request: session.permission!.id, allow: true, always: true }));
  expect(await (await pending).json()).toMatchObject({ hookSpecificOutput: { decision: { behavior: "allow", updatedPermissions: [rule] } } });
  ws.close();
});

test("when the last panel disconnects, held requests get no decision", async () => {
  const { ws, next } = await connect();
  await next(); // snapshot
  const pending = postHook(PERMISSION, permissionUrl());
  await permissionChange(next, true);
  ws.close();
  expect((await pending).status).toBe(204);
});

test("a request no one answers times out with no decision", async () => {
  servers.stop();
  servers = startServers({ hub, token: TOKEN, hookPort: 0, panelPort: 0, permissionHoldMs: 50, desktopSessions: async () => [], codexLibrary: async () => [] });
  const { ws, next } = await connect();
  await next(); // snapshot
  const started = Date.now();
  expect((await postHook(PERMISSION, permissionUrl())).status).toBe(204);
  expect(Date.now() - started).toBeLessThan(1000);
  ws.close();
});

test("a new session starts only in a folder some session ran in, and only one that still exists", async () => {
  const folder = mkdtempSync(`${tmpdir()}/tomari-new-`);
  try {
    desktopSessions = async () => [{ ...DESKTOP[0]!, cwd: folder }];
    const { ws, next } = await connect();
    await next(); // snapshot
    ws.send(JSON.stringify({ type: "new", cwd: "/etc", agent: "claude" }));
    expect(await next()).toEqual({ type: "error", message: "unknown folder" });
    ws.send(JSON.stringify({ type: "new", cwd: folder, agent: "codex" }));
    // A started session sends nothing back: wait for it to reach the runner.
    for (let i = 0; i < 100 && started.length === 0; i++) await Bun.sleep(10);
    expect(started).toEqual([[folder, "codex"]]);

    rmSync(folder, { recursive: true });
    ws.send(JSON.stringify({ type: "new", cwd: folder, agent: "claude" }));
    expect(await next()).toEqual({ type: "error", message: "unknown folder" });
    ws.send(JSON.stringify({ type: "new", cwd: "relative/path", agent: "claude" }));
    expect(await next()).toEqual({ type: "error", message: "invalid message" });
    expect(started).toHaveLength(1);
    ws.close();
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});

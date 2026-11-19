import { FRONT_APPS, type ClientMessage, type SessionIcon } from "../../shared/protocol.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CHARACTER = /^[a-z0-9-]{1,32}$/;
const COLOR = /^#[0-9a-f]{6}$/i;

export function isSessionId(value: unknown): value is string {
  return typeof value === "string" && UUID.test(value);
}

function isIcon(value: unknown): value is SessionIcon {
  const v = value as Partial<SessionIcon> | null;
  return (
    typeof v === "object" &&
    v !== null &&
    typeof v.character === "string" &&
    CHARACTER.test(v.character) &&
    typeof v.color === "string" &&
    COLOR.test(v.color)
  );
}

/** Option indexes per question: AskUserQuestion asks 1 to 4 questions of 2 to 4 options each. */
function isAnswers(value: unknown): value is number[][] {
  return (
    Array.isArray(value) &&
    value.length <= 8 &&
    value.every((chosen) => Array.isArray(chosen) && chosen.length <= 8 && chosen.every((i) => Number.isInteger(i) && i >= 0 && i < 16))
  );
}

/** Parses an untrusted panel message: null unless it is exactly one of the whitelisted ClientMessages. */
export function parseClientMessage(raw: string): ClientMessage | null {
  let msg: Record<string, unknown>;
  try {
    msg = JSON.parse(raw);
  } catch {
    return null;
  }
  if (typeof msg !== "object" || msg === null) return null;
  if (msg.type === "library") return { type: "library" };
  if (msg.type === "terminal") return { type: "terminal" };
  if (msg.type === "new") {
    const { cwd, agent } = msg;
    const folder = typeof cwd === "string" && cwd.startsWith("/") && cwd.length <= 1024 && !cwd.includes("\0");
    return folder && (agent === "claude" || agent === "codex") ? { type: "new", cwd, agent } : null;
  }
  if (msg.type === "frontApp") {
    const app = FRONT_APPS.find((known) => known === msg.app);
    return app ? { type: "frontApp", app } : null;
  }
  if (!isSessionId(msg.id)) return null;

  switch (msg.type) {
    case "open":
      return { type: "open", id: msg.id };
    case "stop":
      return { type: "stop", id: msg.id };
    case "permission": {
      if (!isSessionId(msg.request) || typeof msg.allow !== "boolean") return null;
      const answer: ClientMessage = { type: "permission", id: msg.id, request: msg.request, allow: msg.allow };
      if (msg.always !== undefined) {
        if (typeof msg.always !== "boolean") return null;
        answer.always = msg.always;
      }
      if (msg.answers !== undefined) {
        if (!isAnswers(msg.answers)) return null;
        answer.answers = msg.answers.map((chosen) => [...chosen]);
      }
      return answer;
    }
    case "pin":
      return typeof msg.pinned === "boolean" ? { type: "pin", id: msg.id, pinned: msg.pinned } : null;
    case "icon":
      return isIcon(msg.icon)
        ? { type: "icon", id: msg.id, icon: { character: msg.icon.character, color: msg.icon.color.toLowerCase() } }
        : null;
    default:
      return null;
  }
}

// Firstmate primary turn-end guard for omp (Oh My Pi).
//
// This is the omp port of .pi/extensions/fm-primary-turnend-guard.ts. omp is a
// pi fork loaded by bun. It registers no TUI rendering, so it needs no TUI or
// schema package - only node builtins plus the shared operational-input lib. The
// extension API surface it actually uses is declared locally as OmpExtensionApi
// so the code stays typed without depending on an omp package export that this
// codebase does not pin.
//
// new Promise (rather than Promise.withResolvers) matches the tracked pi
// extensions and the ES2022 typecheck target in tests/fm-pi-primary-types.test.sh;
// withResolvers is ES2024 and would fail that strict no-emit check.
//
// The one behavioural difference from the pi guard is the settle signal. pi
// emits "agent_settled"; omp does not. omp's loop ends on "agent_end", which
// also fires for automatic continuations, so the turn-end guard only runs when
// omp's own settle triple agrees the run is truly idle: event.willContinue is
// false (no continuation already scheduled), ctx.isIdle() is true (no fresh run
// raced the settle), and ctx.hasPendingMessages() is false (no queued input
// still to process). This is the same triple the crewmate omp busy-state
// extension uses to decide idle. The triple is evaluated BEFORE the follow-up
// latch so the latch is only ever consumed on a real settle, matching pi's
// agent_settled semantics.
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  classifyFirstmateCurrentOperationalText,
  encodeFirstmateOperationalInput,
} from "../../extensions/lib/fm-operational-input.ts";

type LockOwnership = "owned" | "missing" | "other";

type SessionStartEvent = { reason?: string };
type ToolCallEvent = { type?: string; toolName?: string; input?: { command?: string } };
type AgentEndEvent = { willContinue?: boolean };
type SettleContext = { isIdle?: () => boolean; hasPendingMessages?: () => boolean };
type ToolCallResult = { block?: boolean; reason?: string };

interface OmpExtensionApi {
  on(event: "session_start", handler: (event: SessionStartEvent) => void | Promise<void>): void;
  on(event: "session_compact", handler: () => void | Promise<void>): void;
  on(event: "tool_call", handler: (event: ToolCallEvent) => ToolCallResult | Promise<ToolCallResult>): void;
  on(event: "agent_end", handler: (event: AgentEndEvent, ctx: SettleContext) => void | Promise<void>): void;
  sendMessage(message: {
    customType: string;
    content: string;
    display: boolean;
    details: { kind: string };
  }): void;
  sendUserMessage(content: string, options: { deliverAs: "followUp" }): Promise<void>;
}

let guardFollowupActive = false;

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const marker = `${state}/.omp-turnend-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded(): void {
  if (!existsSync(state) || lockOwnership() === "other") return;
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

// omp inherits pi's session_start reasons (startup | reload | new | resume |
// fork) and the separate session_compact event. "new" is /clear (a fresh
// session in the SAME process, so the fleet lock is still ours), while reload,
// resume, and fork all keep prior context. bin/fm-sessionstart-run.sh owns what
// each source means; this maps that vocabulary onto its --source names and
// injects whatever it prints.
const sessionstartDeliveryBytes = 512 * 1024;
const sessionstartTruncatedMarker =
  "\n\nOMP SESSION-START DELIVERY TRUNCATED - the digest exceeded 512 KiB. " +
  "Treat omitted context as unread and inspect the named files directly before acting on it.";

function runSessionstartHook(source: string): Promise<string> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/fm-sessionstart-run.sh`, ["--source", source], {
      stdio: ["ignore", "pipe", "ignore"],
    });
    const chunks: Buffer[] = [];
    let retainedBytes = 0;
    let truncated = false;
    child.stdout.on("data", (chunk: Buffer) => {
      if (retainedBytes >= sessionstartDeliveryBytes) {
        truncated = true;
        return;
      }
      const remaining = sessionstartDeliveryBytes - retainedBytes;
      const retained = chunk.length <= remaining ? chunk : chunk.subarray(0, remaining);
      chunks.push(retained);
      retainedBytes += retained.length;
      if (retained.length !== chunk.length) truncated = true;
    });
    child.on("error", () => resolveResult(""));
    child.on("close", (code) => {
      if (code !== 0) {
        resolveResult("");
        return;
      }
      const raw = Buffer.concat(chunks).toString("utf8").trim();
      resolveResult(truncated ? `${raw}${sessionstartTruncatedMarker}` : raw);
    });
  });
}

async function injectSessionstart(pi: OmpExtensionApi, source: string): Promise<void> {
  const raw = await runSessionstartHook(source);
  if (!raw) return;
  try {
    // omp, like pi, injects a MESSAGE rather than hook stdout, so whatever it
    // injects must carry operational provenance or the Ahoy skill would have to
    // guess whether it was captain-authored. The wrapper already returns an
    // encoded nudge on a context-preserving open, so only an unencoded digest
    // needs the marker added here.
    const content = classifyFirstmateCurrentOperationalText(raw)
      ? raw
      : encodeFirstmateOperationalInput("session-start", raw);
    pi.sendMessage({
      customType: "firstmate-sessionstart-nudge",
      content,
      display: false,
      details: { kind: "session-start" },
    });
  } catch {
  }
}

function runGuard(): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/fm-turnend-guard.sh`, {
      stdio: ["pipe", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
    child.stdin.end('{"stop_hook_active":false}');
  });
}

// PreToolUse seatbelts (bin/fm-arm-pretool-check.sh, docs/arm-pretool-check.md;
// bin/fm-cd-pretool-check.sh, docs/cd-guard.md; bin/fm-codegraph-pretool-check.sh,
// docs/codegraph-pretool-check.md). They all piggyback on this same
// extension file rather than separate ones so no extra omp -e flag is needed at
// launch - the primary already loads this file for the turn-end guard, and
// pi.on("tool_call", ...) can block. Each owner script owns its own decision and
// is inert outside the real primary checkout.
function runChecker(script: string, command: string, tool?: string): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const args = tool ? ["--tool", tool, "--command", command] : ["--command", command];
    const child = spawn(`${root}/bin/${script}`, args, {
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  });
}

export default function (pi: OmpExtensionApi) {
  pi.on?.("session_start", async (event) => {
    const reason = String(event.reason ?? "");
    const source = { startup: "startup", new: "clear", resume: "resume", fork: "fork" }[reason];
    markLoaded();
    if (!source) return;
    await injectSessionstart(pi, source);
  });

  // omp's compaction equivalent. The digest is what a compacted session has just
  // lost, so re-emitting it here is the point rather than a side effect.
  pi.on?.("session_compact", async () => {
    await injectSessionstart(pi, "compact");
  });

  pi.on("tool_call", async (event) => {
    if (event.type !== "tool_call" || event.toolName !== "bash") return {};
    const command = String(event.input?.command ?? "");
    if (!command) return {};
    const cdResult = await runChecker("fm-cd-pretool-check.sh", command);
    if (cdResult.code === 2) {
      return { block: true, reason: cdResult.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt" };
    }
    const cgResult = await runChecker("fm-codegraph-pretool-check.sh", command, event.toolName);
    if (cgResult.code === 2) {
      return { block: true, reason: cgResult.stderr.trim() || "denied by the CodeGraph-first PreToolUse seatbelt" };
    }
    const result = await runChecker("fm-arm-pretool-check.sh", command);
    if (result.code !== 2) return {};
    return { block: true, reason: result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt" };
  });

  pi.on("agent_end", async (event, ctx) => {
    if (event && event.willContinue) return;
    if (ctx && typeof ctx.isIdle === "function" && !ctx.isIdle()) return;
    if (ctx && typeof ctx.hasPendingMessages === "function" && ctx.hasPendingMessages()) return;

    if (guardFollowupActive) {
      guardFollowupActive = false;
      return;
    }

    const result = await runGuard();
    if (result.code !== 2) return;

    guardFollowupActive = true;
    try {
      const content = encodeFirstmateOperationalInput(
        "turn-end-guard",
        "TURN WOULD END BLIND - supervision is off. " +
          "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
          result.stderr,
      );
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
    } catch {
      guardFollowupActive = false;
    }
  });

  markLoaded();
}

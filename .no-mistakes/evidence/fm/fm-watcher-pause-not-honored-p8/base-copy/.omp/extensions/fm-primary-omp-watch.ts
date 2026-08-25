// Firstmate primary watcher bridge for omp (Oh My Pi).
//
// This is the omp port of .pi/extensions/fm-primary-pi-watch.ts. omp is a pi
// fork loaded by bun. Unlike the pi watcher it registers no custom TUI shell for
// its tool, so it needs neither the TUI nor the schema package and does not
// depend on the calm-presentation lib; the extension API surface it uses is
// declared locally as OmpExtensionApi. The arm machinery is unchanged: it drives
// bin/fm-watch-arm.sh exactly as the pi watcher does.
//
// new Promise (rather than Promise.withResolvers) matches the tracked pi
// extensions and the ES2022 typecheck target in tests/fm-pi-primary-types.test.sh;
// withResolvers is ES2024 and would fail that strict no-emit check.
//
// Session-generation ownership (stated once here):
// omp emits session_shutdown for ordinary same-process replacements (/new,
// /resume, /fork, reload) as well as terminal quit. This extension binds one
// generation per session activation. Only the active live generation may start,
// stop, rearm, or clear the arm child. Replacement session_start (or a fresh
// factory bind) activates a new live generation so monitoring can arm again
// without restarting omp. Terminal quit leaves the final generation stopped so
// late callbacks cannot rearm. Stale callbacks from a prior generation are
// no-ops against the active replacement.
//
// Wake coalescing (contract stated once in docs/watcher-continuity.md):
// each generation keeps one pending watcher wake until the run starts consuming
// queued input, so a burst of distinct actionable lines queues one follow-up,
// not one per cycle. The durable wake queue carries every underlying event.
// The ledger is cleared when a run starts consuming queued input (agent_start)
// and at generation activation and retirement; anything it cannot answer is
// delivered.
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { encodeFirstmateOperationalInput } from "../../extensions/lib/fm-operational-input.ts";

type ArmResult = {
  ok: boolean;
  message: string;
};

type LockOwnership = "owned" | "missing" | "other";

type CloseClassification = {
  kind: "actionable" | "failure";
  message: string;
};

type SessionGeneration = {
  id: number;
  stopping: boolean;
  child: ChildProcess | null;
  retryTimer: NodeJS.Timeout | null;
  retryFailures: number;
  restoring: boolean;
  seq: number;
  deliveredWakes: Map<string, number>;
};

interface OmpToolSpec {
  name: string;
  label: string;
  description: string;
  promptSnippet: string;
  promptGuidelines: string[];
  // omp accepts a plain JSON-schema object for tool parameters; this tool takes
  // none. The pi watcher used typebox Type.Object({}) here, which is not needed
  // once the custom TUI rendering is dropped.
  parameters: { type: "object"; properties: Record<string, unknown> };
  execute: () => Promise<{
    content: Array<{ type: "text"; text: string }>;
    details: ArmResult;
  }>;
}

interface OmpCommandSpec {
  description: string;
  handler: (
    args: unknown,
    ctx: { ui: { notify: (message: string, level: "info" | "warning") => void } },
  ) => void | Promise<void>;
}

interface OmpExtensionApi {
  on(event: "session_start" | "session_shutdown" | "agent_start", handler: () => void): void;
  registerCommand(name: string, spec: OmpCommandSpec): void;
  registerTool(spec: OmpToolSpec): void;
  sendUserMessage(content: string, options: { deliverAs: "followUp" }): Promise<void>;
}

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const marker = `${state}/.omp-watch-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;
const retryBaseMs = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const retryMaxMs = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const retryLimit = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);
// 35s on Windows so the budget stays above arm's MSYS confirm default (30s in
// bin/fm-watch-arm.sh): a slow but successful Git Bash cold start must not be
// SIGTERMed mid-confirmation. Conditioned on win32 so other platforms keep 12s.
const armReadyTimeoutMs = positiveInteger(
  "FM_OMP_ARM_READY_TIMEOUT_MS",
  process.platform === "win32" ? 35000 : 12000,
);
const armRetireTimeoutMs = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const wakeCoalesceTtlMs = positiveInteger("FM_WATCH_WAKE_COALESCE_TTL_MS", 300000);
const wakeLedgerLimit = 64;
const pendingWakeKey = "watcher-wake-pending";
const repairOnlyHint = "call fm_watch_arm_omp again only after a later notification says the cycle is missing, failed, or unhealthy";
const shuttingDownMessage = "watcher: not armed - omp session is shutting down";

let nextGenerationId = 0;
let activeGeneration: SessionGeneration | null = null;
// Set the first time omp reports that a run began consuming queued input. Until
// then the coalesce TTL is the fail-open bound; after it the ledger is trusted.
let consumptionBoundaryObserved = false;
const armReadiness = new WeakMap<ChildProcess, Promise<boolean>>();
const armClose = new WeakMap<ChildProcess, Promise<void>>();

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

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
  if (lockOwnership() === "other") return;
  mkdirSync(state, { recursive: true });
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function actionableLine(output: string): string {
  const lines = output.split(/\r?\n/);
  return lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line)) || "";
}

function classifyClose(stdout: string, stderr: string, code: number | null, signal: NodeJS.Signals | null): CloseClassification {
  const combined = `${stdout}\n${stderr}`.trim();
  const reason = actionableLine(combined);
  if (reason) return { kind: "actionable", message: reason };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - omp extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`,
    };
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - omp extension arm child ended from ${signal}${combined ? `\n${combined}` : ""}`,
    };
  }
  if (code && code !== 0) {
    return {
      kind: "failure",
      message: `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`,
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - omp extension arm cycle ended without an actionable reason",
  };
}

function createGeneration(): SessionGeneration {
  return {
    id: ++nextGenerationId,
    stopping: false,
    child: null,
    retryTimer: null,
    retryFailures: 0,
    restoring: false,
    seq: 0,
    deliveredWakes: new Map(),
  };
}

function generationIsLive(generation: SessionGeneration): boolean {
  return activeGeneration === generation && !generation.stopping;
}

function clearWakeLedger(generation: SessionGeneration): void {
  if (generation.deliveredWakes instanceof Map) generation.deliveredWakes.clear();
}

// True when this pending watcher wake must be delivered. False only when one is
// already queued and unconsumed. Every uncertain case delivers, because losing a
// wake is worse than repeating one: no usable ledger, a clock that moved
// backwards, a ledger already at its bound, or - while this session has never
// once reported a consumption boundary - an entry older than the coalesce TTL,
// which is the fail-open bound for a harness that never reports one.
function claimWakeDelivery(generation: SessionGeneration, message: string): boolean {
  const ledger = generation.deliveredWakes;
  if (!(ledger instanceof Map)) return true;
  const now = Date.now();
  const pendingSince = ledger.get(message);
  if (pendingSince !== undefined) {
    const age = now - pendingSince;
    const expired = !consumptionBoundaryObserved && age >= wakeCoalesceTtlMs;
    if (age >= 0 && !expired) return false;
  }
  // Only a genuinely new key grows the ledger. Refreshing an existing expired
  // entry must not evict a different message's record, because that record is
  // the only thing keeping that other message from being delivered twice.
  if (pendingSince === undefined && ledger.size >= wakeLedgerLimit) {
    const oldest = ledger.keys().next();
    if (!oldest.done) ledger.delete(oldest.value);
  }
  ledger.set(message, now);
  return true;
}

function releaseWakeDelivery(generation: SessionGeneration, message: string): void {
  if (generation.deliveredWakes instanceof Map) generation.deliveredWakes.delete(message);
}

function stopGeneration(generation: SessionGeneration): void {
  generation.stopping = true;
  if (generation.retryTimer) {
    clearTimeout(generation.retryTimer);
    generation.retryTimer = null;
  }
  if (generation.child) generation.child.kill("SIGTERM");
  clearWakeLedger(generation);
  generation.child = null;
}

const cleanupOnProcessExit = () => {
  if (activeGeneration) stopGeneration(activeGeneration);
};
process.once("exit", cleanupOnProcessExit);

export default function (pi: OmpExtensionApi) {
  let generation = createGeneration();
  activeGeneration = generation;

  async function sendWake(owner: SessionGeneration, message: string): Promise<void> {
    if (!generationIsLive(owner)) return;
    if (!claimWakeDelivery(owner, pendingWakeKey)) return;
    try {
      const content = encodeFirstmateOperationalInput(
        "watcher",
        `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.`,
      );
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
    } catch (error) {
      // Nothing was queued, so the ledger must not claim a pending copy.
      releaseWakeDelivery(owner, pendingWakeKey);
      throw error;
    }
  }

  function surfaceFailure(owner: SessionGeneration, message: string): void {
    void sendWake(owner, message).catch(() => {
      // omp owns delivery errors; continuity restoration never waits on prompting.
    });
  }

  function retryDelay(attempt: number): number {
    return Math.min(retryMaxMs, retryBaseMs * 2 ** Math.max(0, attempt - 1));
  }

  function waitForRetry(attempt: number): Promise<void> {
    return new Promise((resolveRetry) => {
      const timer = setTimeout(resolveRetry, retryDelay(attempt));
      timer.unref();
    });
  }

  function waitForReadiness(armChild: ChildProcess): Promise<boolean> {
    const readiness = armReadiness.get(armChild);
    if (!readiness) return Promise.resolve(false);
    return new Promise((resolveReady) => {
      const timer = setTimeout(() => resolveReady(false), armReadyTimeoutMs);
      timer.unref();
      void readiness.then((ready) => {
        clearTimeout(timer);
        resolveReady(ready);
      });
    });
  }

  async function retireArm(armChild: ChildProcess | null): Promise<boolean> {
    if (!armChild) return true;
    armChild.kill("SIGTERM");
    const closed = armClose.get(armChild);
    if (!closed) return false;
    return new Promise((resolveRetired) => {
      const timer = setTimeout(() => resolveRetired(false), armRetireTimeoutMs);
      timer.unref();
      void closed.then(() => {
        clearTimeout(timer);
        resolveRetired(true);
      });
    });
  }

  async function restoreAfterActionableClose(owner: SessionGeneration, predecessorArmPid: string): Promise<string> {
    let failure = "";
    for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
      if (!generationIsLive(owner)) return "";
      const replacement = startArm(owner, predecessorArmPid);
      const successorChild = owner.child;
      if (replacement.ok && successorChild && await waitForReadiness(successorChild)) return "";
      if (replacement.ok) {
        failure = "watcher: FAILED - omp extension could not verify a ready successor watcher";
        if (!(await retireArm(successorChild))) {
          return `${failure}\nwatcher: FAILED - omp extension could not restore watcher continuity because the unready successor arm did not exit within ${armRetireTimeoutMs}ms`;
        }
      } else {
        failure = /(?:read-only|no live session)/.test(replacement.message)
          ? `watcher: FAILED - omp extension cannot restore continuity because this session no longer owns the lock\n${replacement.message}`
          : `watcher: FAILED - omp extension could not start the successor watcher cycle\n${replacement.message}`;
        if (/(?:read-only|no live session)/.test(replacement.message)) break;
      }
      if (attempt === retryLimit) break;
      await waitForRetry(attempt + 1);
    }
    return `${failure}\nwatcher: FAILED - omp extension could not restore watcher continuity after ${retryLimit} retries`;
  }

  function scheduleRetry(owner: SessionGeneration, message: string, predecessorArmPid: string): void {
    if (!generationIsLive(owner) || owner.child || owner.retryTimer) return;
    const ownership = lockOwnership();
    if (ownership !== "owned") {
      surfaceFailure(owner, `watcher: FAILED - omp extension cannot restore continuity because this session no longer owns the lock\n${message}`);
      return;
    }
    owner.retryFailures += 1;
    if (owner.retryFailures > retryLimit) {
      surfaceFailure(owner, `watcher: FAILED - omp extension could not restore watcher continuity after ${retryLimit} retries\n${message}`);
      return;
    }
    const timer = setTimeout(() => {
      if (owner.retryTimer === timer) owner.retryTimer = null;
      if (!generationIsLive(owner)) return;
      const result = startArm(owner, predecessorArmPid);
      if (!result.ok) {
        surfaceFailure(owner, `watcher: FAILED - omp extension could not launch a continuity retry\n${result.message}`);
      }
    }, retryDelay(owner.retryFailures));
    timer.unref();
    owner.retryTimer = timer;
  }

  function startArm(owner: SessionGeneration, predecessorArmPid = ""): ArmResult {
    if (!generationIsLive(owner)) return { ok: false, message: shuttingDownMessage };
    const ownership = lockOwnership();
    if (ownership === "other") return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    if (ownership === "missing") {
      return {
        ok: false,
        message: "watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, then call fm_watch_arm_omp to re-arm",
      };
    }
    markLoaded();
    if (owner.child) {
      return {
        ok: true,
        message: `watcher: unchanged - omp extension already owns an arm child; no manual re-arm needed; ${repairOnlyHint}`,
      };
    }
    if (owner.retryTimer) {
      return {
        ok: true,
        message: `watcher: unchanged - omp extension already owns a scheduled continuity retry; no manual re-arm needed; ${repairOnlyHint}`,
      };
    }
    const id = ++owner.seq;
    const env = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_CONFIG_OVERRIDE: config,
      FM_WATCH_ARM_SCRIPT: armScript,
      FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid,
    };
    const armChild = spawn("bash", ["-lc", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"], {
      cwd: fmRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    owner.child = armChild;
    let stdout = "";
    let stderr = "";
    let settled = false;
    let readinessSettled = false;
    let resolveReadiness: (ready: boolean) => void = () => {};
    let resolveClosed: () => void = () => {};
    const readiness = new Promise<boolean>((resolveReady) => {
      resolveReadiness = resolveReady;
    });
    armReadiness.set(armChild, readiness);
    const closed = new Promise<void>((resolveClosedChild) => {
      resolveClosed = resolveClosedChild;
    });
    armClose.set(armChild, closed);
    const settleReadiness = (ready: boolean): void => {
      if (readinessSettled) return;
      readinessSettled = true;
      resolveReadiness(ready);
    };
    const observeEstablishedArm = (): void => {
      if (/^watcher: (?:started|attached)\b/m.test(`${stdout}\n${stderr}`)) {
        settleReadiness(true);
      }
    };
    const releaseChild = (): void => {
      if (owner.child === armChild) owner.child = null;
    };
    armChild.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      observeEstablishedArm();
    });
    armChild.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
      observeEstablishedArm();
    });
    armChild.on("close", (code: number | null, signal: NodeJS.Signals | null) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (!generationIsLive(owner)) return;
      const classification = classifyClose(stdout, stderr, code, signal);
      const predecessor = String(armChild.pid ?? "");
      if (classification.kind === "actionable") {
        owner.retryFailures = 0;
        owner.restoring = true;
        void (async () => {
          const failure = await restoreAfterActionableClose(owner, predecessor);
          if (generationIsLive(owner)) owner.restoring = false;
          if (!generationIsLive(owner)) return;
          const message = failure ? `${classification.message}\n\n${failure}` : classification.message;
          await sendWake(owner, message);
        })().catch(() => {
        });
        return;
      }
      if (owner.restoring) return;
      scheduleRetry(owner, classification.message, predecessor);
    });
    armChild.on("error", (error: Error) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (!generationIsLive(owner)) return;
      if (owner.restoring) return;
      scheduleRetry(owner, `watcher: FAILED - omp extension arm child ${id} failed: ${error.message}`, String(armChild.pid ?? ""));
    });
    return {
      ok: true,
      message: `watcher: started omp extension arm child ${id}; future ordinary re-arms are automatic; ${repairOnlyHint}`,
    };
  }

  pi.on?.("agent_start", () => {
    clearWakeLedger(generation);
    consumptionBoundaryObserved = true;
  });
  pi.on?.("session_start", () => {
    if (generation.stopping) generation = createGeneration();
    activeGeneration = generation;
    clearWakeLedger(generation);
    markLoaded();
  });
  pi.on?.("session_shutdown", () => {
    stopGeneration(generation);
  });

  pi.registerCommand?.("fm-watch-arm-omp", {
    description: "Arm firstmate watcher supervision through the omp extension instead of foreground bash.",
    handler: (_args, ctx) => {
      const result = startArm(generation);
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    },
  });

  pi.registerTool?.({
    name: "fm_watch_arm_omp",
    label: "Arm firstmate watcher",
    description: "Start the first required omp watcher cycle, or repair one only after a notification says the cycle is missing, failed, or unhealthy. Do not call after ordinary work or ordinary notifications; the omp extension re-arms automatically. Never run bin/fm-watch-arm.sh through bash.",
    promptSnippet: "Start the first required omp watcher cycle or repair a cycle reported missing, failed, or unhealthy; ordinary re-arming is automatic.",
    promptGuidelines: [
      "Call fm_watch_arm_omp only for the first required cycle or after a notification says the cycle is missing, failed, or unhealthy. Do not call it after ordinary work, turn completion, or ordinary signal, stale, check, or heartbeat handling because the omp extension owns re-arming. Never run bin/fm-watch-arm.sh through bash.",
    ],
    parameters: { type: "object", properties: {} },
    execute: async () => {
      const result = startArm(generation);
      return {
        content: [{ type: "text", text: result.message }],
        details: result,
      };
    },
  });

  markLoaded();
}

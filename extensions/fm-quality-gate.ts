/**
 * Absolute quality-band reporter for every pi and omp session.
 *
 * This is ONE portable source file loaded by both runtimes: omp discovers it in
 * ~/.omp/agent/extensions/, and pi loads it as an installed package that points
 * at this same path (see docs/quality-score-gate.md).
 * It therefore declares the extension API surface locally instead of importing
 * @oh-my-pi/pi-coding-agent or @earendil-works/pi-coding-agent, whose package
 * names differ between the two runtimes.
 *
 * At turn end it runs bin/fm-quality-score-check.sh, which owns the whole band
 * decision. Exit 2 means the CURRENT sentrux quality score is below the floor;
 * the checker's stderr is then surfaced to the session as a visible message.
 * Every other outcome - exit 0, a spawn error, a missing script - is silent.
 *
 * This hook REPORTS, it does not block. A user extension cannot refuse a turn
 * end the way the Claude Stop hook can, and faking a block by injecting a
 * follow-up would fight the primary turn-end guard for the same continuation
 * budget. The enforcing arm of the band is the Claude Stop hook; here the agent
 * is told, in the session, that the change is not shippable.
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";

type AgentEndEvent = { willContinue?: boolean };

type SettleContext = {
  cwd?: string;
  isIdle?: () => boolean;
  hasPendingMessages?: () => boolean;
};

interface QualityExtensionApi {
  on(event: "agent_end", handler: (event: AgentEndEvent, ctx: SettleContext) => void | Promise<void>): void;
  sendMessage(message: {
    customType: string;
    content: string;
    display: boolean;
    details: { kind: string };
  }): void;
}

// The checker is resolved from a STABLE installed path, never from a working
// tree. The sibling CodeGraph guard learned this the hard way: pointing at
// ${FM_HOME}/bin/... silently disabled the guard the moment anyone checked out
// a branch that did not carry the script, because the spawn failed and the
// handler fails open by design. The repo copy remains the source of truth; this
// is the installed artifact. The repo path stays as a fallback so a checkout
// that does carry a newer script still works.
const INSTALLED_CHECKER = `${process.env.HOME || "/home/ubuntu"}/.local/bin/fm-quality-score-check.sh`;
const FM_HOME = process.env.FM_HOME || "/home/ubuntu/Dev/firstmate";
const REPO_CHECKER = `${FM_HOME}/bin/fm-quality-score-check.sh`;
const CHECKER = existsSync(INSTALLED_CHECKER) ? INSTALLED_CHECKER : REPO_CHECKER;

function runChecker(cwd: string): Promise<{ code: number; stderr: string }> {
  const { promise, resolve } = Promise.withResolvers<{ code: number; stderr: string }>();
  const child = spawn(CHECKER, ["--cwd", cwd], { stdio: ["ignore", "ignore", "pipe"] });
  let stderr = "";
  child.stderr.on("data", (chunk: Buffer) => {
    stderr += chunk.toString();
  });
  child.on("error", () => resolve({ code: 0, stderr: "" }));
  child.on("close", (code) => resolve({ code: code ?? 0, stderr }));
  return promise;
}

export default function (pi: QualityExtensionApi) {
  // pi settles on "agent_settled", omp has no such event and ends its loop on
  // "agent_end", which also fires for automatic continuations. "agent_end" is
  // the event BOTH runtimes expose, so the settle triple is checked here and
  // the band is measured only on a real turn end: willContinue is false, the
  // run is idle, and no queued input is still to process. Under pi the triple's
  // members are simply absent, which reads as settled.
  pi.on("agent_end", async (event, ctx) => {
    if (event?.willContinue === true) return;
    if (ctx?.isIdle && !ctx.isIdle()) return;
    if (ctx?.hasPendingMessages && ctx.hasPendingMessages()) return;

    const result = await runChecker(ctx?.cwd || process.cwd());
    if (result.code !== 2) return;

    const reason = result.stderr.trim() || "the current quality score is below the FM_QUALITY_MIN floor";
    try {
      pi.sendMessage({
        customType: "firstmate-quality-band",
        content: `Quality band breach (reported, not blocked):\n${reason}`,
        display: true,
        details: { kind: "quality-band" },
      });
    } catch {
    }
  });
}

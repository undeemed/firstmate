/**
 * CodeGraph-first PreToolUse seatbelt for every pi and omp session.
 *
 * This is ONE portable source file loaded by both runtimes: omp discovers it in
 * ~/.omp/agent/extensions/, and pi loads it as an installed package that points
 * at this same path (see docs/codegraph-pretool-check.md).
 * It therefore declares the extension API surface locally instead of importing
 * @oh-my-pi/pi-coding-agent or @earendil-works/pi-coding-agent, whose package
 * names differ between the two runtimes.
 *
 * Every tool call is forwarded to bin/fm-codegraph-pretool-check.sh, which owns
 * the whole allow/deny decision. Exit 2 blocks the call with the checker's
 * stderr as the reason, and exit 0 allows.
 *
 * Anything else means the guard could not RUN: no checker on disk, a spawn
 * failure, or an exit code the contract does not define. That case is handled
 * here rather than by the checker, because a checker that never started cannot
 * report anything. See "When the guard cannot run" below.
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

type ToolCallEvent = {
  type?: string;
  toolName?: string;
  input?: Record<string, unknown>;
};

type ToolCallContext = { cwd?: string };

type ToolCallResult = { block?: boolean; reason?: string };

interface GuardExtensionApi {
  on(
    event: "tool_call",
    handler: (event: ToolCallEvent, ctx: ToolCallContext) => ToolCallResult | Promise<ToolCallResult>,
  ): void;
}

// The checker is resolved from a STABLE installed path first, never only from a
// working tree. An earlier version pointed at ${FM_HOME}/bin/..., which silently
// disabled this guard the moment anyone checked out a branch that did not carry
// the script: the spawn failed and the handler allowed, so nothing was logged
// and every raw search was allowed again. The repo copy remains the source of
// truth; this is the installed artifact. The repo path stays as a fallback so a
// checkout that does carry a newer script still works.
//
// FM_CODEGRAPH_CHECKER pins an explicit checker ahead of both, so one session
// can exercise a candidate script without rewriting the shared installed copy
// that every other agent on the machine is already running.
const INSTALLED_CHECKER = `${process.env.HOME || "/home/ubuntu"}/.local/bin/fm-codegraph-pretool-check.sh`;
const FM_HOME = process.env.FM_HOME || "/home/ubuntu/Dev/firstmate";
const REPO_CHECKER = `${FM_HOME}/bin/fm-codegraph-pretool-check.sh`;

const DEFAULT_BLOCK_REASON = "denied by the CodeGraph-first PreToolUse seatbelt";

// Structured code-search tool names across the harnesses this guard runs in:
// pi (grep/find), Claude (Grep/Glob), and the ast_grep/ripgrep/search spellings.
const SEARCH_TOOLS = new Set([
  "grep",
  "glob",
  "find",
  "search",
  "ast_grep",
  "ast-grep",
  "astgrep",
  "ripgrep",
]);

// A deliberately broad "this might be a search" test used ONLY on the
// cannot-run path. It over-matches on purpose: the exact rule lives in the
// checker, and this only has to decide which calls are unsafe to wave through
// while the real rule is unavailable.
const SEARCH_WORD = /(^|[\s;&|(])(rg|grep|egrep|fgrep|ag|ack|fd|find|ast-grep)([\s;&|)]|$)/;
const INLINE_ESCAPE_HATCH = /(^|\s)FM_ALLOW_RAW_SEARCH=1(\s|$)/;

// The checker is resolved per call, not once at load, so installing or removing
// it mid-session takes effect immediately.
function resolveChecker(): string | null {
  const pinned = process.env.FM_CODEGRAPH_CHECKER;
  if (pinned && existsSync(pinned)) return pinned;
  if (existsSync(INSTALLED_CHECKER)) return INSTALLED_CHECKER;
  if (existsSync(REPO_CHECKER)) return REPO_CHECKER;
  return null;
}

// The same repo-boundary rule the checker applies: the walk stops at the first
// Git working tree, and the repository is indexed only when that root carries a
// .codegraph/ index. A .codegraph/ further up the filesystem belongs to another
// project and must not make this one look indexed.
function indexedRepoRoot(cwd: string): string | null {
  let dir: string;
  try {
    dir = resolve(cwd);
  } catch {
    return null;
  }
  for (;;) {
    if (existsSync(join(dir, ".git"))) {
      return existsSync(join(dir, ".codegraph")) ? dir : null;
    }
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

function looksLikeSearch(tool: string, command: string): boolean {
  if (SEARCH_TOOLS.has(tool.toLowerCase())) return true;
  return SEARCH_WORD.test(command);
}

/**
 * When the guard cannot run.
 *
 * A guard that quietly allows everything is indistinguishable from a guard that
 * approved the call, so the unavailable case must not be silent. It also must
 * not refuse everything: this handler sees EVERY tool call, so a blanket refusal
 * would block reading, writing, editing, and running commands - including the
 * commands needed to reinstall the missing checker - and wedge the session.
 *
 * The refusal is therefore scoped to exactly the class this guard exists to
 * judge: a search-shaped call inside a CodeGraph-indexed repository. Everything
 * else keeps working, and the refusal names the missing checker so the fix is
 * one step away. Outside an indexed repository the guard has nothing to enforce,
 * so its absence changes nothing and the call proceeds.
 */
function guardUnavailable(tool: string, command: string, cwd: string, why: string): ToolCallResult {
  if (process.env.FM_ALLOW_RAW_SEARCH === "1") return {};
  if (INLINE_ESCAPE_HATCH.test(command)) return {};
  const repo = indexedRepoRoot(cwd);
  if (!repo) return {};
  if (!looksLikeSearch(tool, command)) return {};
  return {
    block: true,
    reason: [
      `Refused a search-shaped ${tool} call: the CodeGraph-first search guard could not run (${why}).`,
      `This repository is CodeGraph-indexed (.codegraph/ at ${repo}), so raw search is normally refused here and the guard cannot confirm this call is allowed.`,
      `Use codegraph explore instead, or reinstall the checker:`,
      `  install -m 0755 "${REPO_CHECKER}" "${INSTALLED_CHECKER}"`,
      `To run the raw search anyway, set FM_ALLOW_RAW_SEARCH=1 (environment or inline prefix).`,
    ].join("\n"),
  };
}

type CheckerOutcome = { code: number; stderr: string; error?: string };

function runChecker(checker: string, tool: string, command: string, cwd: string): Promise<CheckerOutcome> {
  return new Promise((resolveOutcome) => {
    const child = spawn(checker, ["--tool", tool, "--command", command, "--cwd", cwd], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString();
    });
    child.on("error", (err: Error) => resolveOutcome({ code: -1, stderr: "", error: err.message }));
    child.on("close", (code) => resolveOutcome({ code: code ?? -1, stderr }));
  });
}

export default function (pi: GuardExtensionApi) {
  pi.on("tool_call", async (event, ctx) => {
    const tool = String(event.toolName ?? "");
    if (!tool) return {};

    // The command bytes the checker classifies. A shell tool call carries the
    // command itself; a structured tool call carries none, so its input is
    // serialized and the checker recovers the path and pattern from it.
    const rawCommand = event.input?.command;
    let command = "";
    if (typeof rawCommand === "string") {
      command = rawCommand;
    } else if (event.input) {
      try {
        command = JSON.stringify(event.input);
      } catch {
        command = "";
      }
    }

    const cwd = ctx?.cwd || process.cwd();
    const checker = resolveChecker();
    if (!checker) {
      return guardUnavailable(tool, command, cwd, `no checker at ${INSTALLED_CHECKER} or ${REPO_CHECKER}`);
    }

    const result = await runChecker(checker, tool, command, cwd);
    if (result.code === 0) return {};
    if (result.code === 2) {
      return { block: true, reason: result.stderr.trim() || DEFAULT_BLOCK_REASON };
    }
    return guardUnavailable(tool, command, cwd, result.error ?? `${checker} exited ${result.code}`);
  });
}

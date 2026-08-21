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
 * stderr as the reason; every other outcome - exit 0, a spawn error, a missing
 * script - allows.
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";

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

// The checker is resolved from a STABLE installed path, never from a working
// tree. An earlier version pointed at ${FM_HOME}/bin/..., which silently
// disabled this guard the moment anyone checked out a branch that did not
// carry the script: the spawn failed and the handler fails open by design, so
// nothing was logged and every raw search was allowed again. The repo copy
// remains the source of truth; this is the installed artifact. The repo path
// stays as a fallback so a checkout that does carry a newer script still works.
const INSTALLED_CHECKER = `${process.env.HOME || "/home/ubuntu"}/.local/bin/fm-codegraph-pretool-check.sh`;
const FM_HOME = process.env.FM_HOME || "/home/ubuntu/Dev/firstmate";
const REPO_CHECKER = `${FM_HOME}/bin/fm-codegraph-pretool-check.sh`;
const CHECKER = existsSync(INSTALLED_CHECKER) ? INSTALLED_CHECKER : REPO_CHECKER;

function runChecker(tool: string, command: string, cwd: string): Promise<{ code: number; stderr: string }> {
  const { promise, resolve } = Promise.withResolvers<{ code: number; stderr: string }>();
  const child = spawn(CHECKER, ["--tool", tool, "--command", command, "--cwd", cwd], {
    stdio: ["ignore", "ignore", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk: Buffer) => {
    stderr += chunk.toString();
  });
  child.on("error", () => resolve({ code: 0, stderr: "" }));
  child.on("close", (code) => resolve({ code: code ?? 0, stderr }));
  return promise;
}

export default function (pi: GuardExtensionApi) {
  pi.on("tool_call", async (event, ctx) => {
    const tool = String(event.toolName ?? "");
    if (!tool) return {};

    // The command bytes the checker classifies. A shell tool call carries the
    // command itself; a structured tool call carries none, so its input is
    // serialized and the checker decides on the tool name alone.
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

    const result = await runChecker(tool, command, ctx?.cwd || process.cwd());
    if (result.code !== 2) return {};
    return {
      block: true,
      reason: result.stderr.trim() || "denied by the CodeGraph-first PreToolUse seatbelt",
    };
  });
}

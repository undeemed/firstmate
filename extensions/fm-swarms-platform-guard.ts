// fm-swarms-platform-guard - PreToolUse seatbelt for swarms-platform work.
//
// Instruction did not hold. On 2026-09-10 three separate rules were broken by
// workers and by the validation pipeline, each already written in the crewmate
// contract and each still shipped to the maintainer:
//
//   1. vercel.json was edited twice to add
//      git.deploymentEnabled: { "<our-branch>": false }, writing a disposable
//      fork branch name into the maintainer's permanent deploy config to
//      silence a red preview check that is an ACCESS gate, not a build failure.
//      Authors: the pipeline's ci auto-fixer on #1166, a worker on #1179/#1180.
//   2. Pull-request titles were published in conventional-commit form four
//      times (#1166, #1167, #1179, #1180) against a repo whose stated standard
//      is the WARP bracket form. Each was corrected by hand after publication.
//   3. Commits were written with --no-verify, bypassing the clone's commit-msg
//      hook that enforces that same WARP form.
//
// A guard that blocks the call is the only enforcement that survives an agent
// that did not read, or a pipeline that never reads at all. This runs as a
// tool_call handler: return { block: true, reason } and the call never happens.
//
// SCOPE: fires only when the working directory is a swarms-platform checkout,
// so every other project on this box is untouched.

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
    handler: (event: ToolCallEvent, ctx: ToolCallContext) => ToolCallResult,
  ): void;
}

const ALLOW: ToolCallResult = {};

// WARP bracket form: [TYPE][Module][Description]. The repo's own commit-msg
// hook requires an uppercase four-letter type in slot one; PR titles in the
// repo's history use English words there too, so both are accepted here and
// only the SHAPE is enforced.
const WARP_TITLE = /^\[[A-Za-z]+\]\[[^\]]+\]\[[^\]]+\]/;
// A shell write AIMED at vercel.json: a redirect, tee, in-place sed, or cp/mv
// whose target is that path. The bare filename inside a quoted message written
// somewhere else (a status line, a grep pattern) must not fire, or the guard
// costs the crewmate turns for nothing.
const VERCEL_PATH = String.raw`(?:[^\s'";|&]*\/)?vercel\.json\b`;
const VERCEL_WRITE = new RegExp(
  [
    String.raw`(?:>>?|\btee\b(?:\s+-[a-z]+)*)\s*['"]?${VERCEL_PATH}`,
    String.raw`\bsed\s+-[a-zA-Z]*i[a-zA-Z]*\b[^|;&]*\s['"]?${VERCEL_PATH}`,
    String.raw`\b(?:cp|mv)\b[^|;&]*\s['"]?${VERCEL_PATH}['"]?\s*(?:$|[;|&])`,
  ].join("|"),
);

// A missing ctx.cwd must not silently unguard the crewmate, so fall back to
// the pi process's own working directory, which is the task worktree.
function inSwarmsPlatform(cwd: string | undefined): boolean {
  const dir = cwd || (typeof process !== "undefined" ? process.cwd() : "");
  return /swarms-platform/.test(dir);
}

function textOf(input: Record<string, unknown> | undefined, keys: string[]): string {
  if (!input) return "";
  for (const k of keys) {
    const v = input[k];
    if (typeof v === "string" && v.length) return v;
  }
  return "";
}

// A --title/-t value, whether quoted with ' or " or left bare.
function extractTitle(command: string): string | null {
  const m =
    command.match(/--title[= ]+'([^']*)'/) ||
    command.match(/--title[= ]+"([^"]*)"/) ||
    command.match(/(?:^|\s)-t[= ]+'([^']*)'/) ||
    command.match(/(?:^|\s)-t[= ]+"([^"]*)"/);
  return m ? m[1] : null;
}

export default function (pi: GuardExtensionApi): void {
  pi.on("tool_call", (event, ctx): ToolCallResult => {
    if (!inSwarmsPlatform(ctx?.cwd)) return ALLOW;

    const tool = (event?.toolName || "").toLowerCase();
    const input = event?.input;

    // 1. vercel.json is never ours to edit.
    const path = textOf(input, ["path", "file_path", "filePath", "target"]);
    if (path && /(^|\/)vercel\.json$/.test(path)) {
      return {
        block: true,
        reason:
          "vercel.json must never be edited on this repo. The red Vercel check is an ACCESS gate " +
          "- the git author is not on the Swarms Vercel team, so the deploy bot refuses every " +
          "branch from our fork - and the maintainer merges with that red daily (#1159, #1173, " +
          "#1168). Disabling the preview writes our disposable branch name permanently into his " +
          "deploy config. Leave the check red and say so in the pull-request body instead.",
      };
    }

    const command = textOf(input, ["command", "cmd", "script"]);
    if (!command) return ALLOW;

    // Same file, reached through a shell instead of the edit tool.
    if (VERCEL_WRITE.test(command)) {
      return {
        block: true,
        reason:
          "this command writes vercel.json, which must never be edited on this repo - the red " +
          "Vercel check is a team-access gate, not a build failure. Leave it red.",
      };
    }

    // 2. Never bypass the clone's WARP commit-msg hook. Scoped to the commit
    // and push verbs themselves so a compound line like
    // `git log -n 3 && git commit -m ...` is not blocked on the unrelated -n.
    if (
      /\bgit\s+commit\b[^|;&]*(--no-verify|\s-n\b)/.test(command) ||
      /\bgit\s+push\b[^|;&]*--no-verify\b/.test(command)
    ) {
      return {
        block: true,
        reason:
          "--no-verify bypasses this clone's commit-msg hook, which enforces the WARP bracket " +
          "form the maintainer requires. Write a conforming subject - [TYPE][Module][Short " +
          "description] - and let the hook pass.",
      };
    }

    // 2b. Never rewrite published history. A forward commit is the remedy:
    // GitHub recomputes a pull request's diff against its base, so a revert
    // shrinks the published change without breaking a branch a reviewer may
    // already have fetched.
    if (/\bgit\s+push\b[^|;&]*(--force\b|--force-with-lease\b|\s-f\b)/.test(command)) {
      return {
        block: true,
        reason:
          "force-pushing published work is not authorised on this repo. Shrink or correct a " +
          "pull request with a FORWARD COMMIT instead - GitHub recomputes the diff against the " +
          "base, so a revert commit reduces the published file count without rewriting history " +
          "or breaking a branch a reviewer already fetched.",
      };
    }

    // 3. A published pull-request title must carry the WARP shape.
    if (/\bgh\b/.test(command) && /\bpr\b/.test(command) && /\b(create|edit)\b/.test(command)) {
      const title = extractTitle(command);
      if (title !== null && !WARP_TITLE.test(title)) {
        return {
          block: true,
          reason:
            `pull-request title ${JSON.stringify(title)} is not in WARP bracket form. This repo's ` +
            "titles are [TYPE][Module][Short description]; conventional-commit titles have been " +
            "corrected by hand four times today. Retitle and retry.",
        };
      }
    }

    // 4. Backend infrastructure is never a lane's to build or change. ONE
    // shared Supabase stack (~/oss-fleet/shared-supabase, API :54321) serves
    // every lane and its database is a read-only test fixture - there is never
    // a migration (captain, 2026-09-17). On 2026-09-17 two full local stacks
    // plus three stray Postgres containers, each built by a lane that only
    // needed a screenshot, sat in 52 GB of swap. A Docker-level guard removes
    // any second stack on creation and the DB rejects DDL; this rule stops the
    // attempt one step earlier, with the reason attached.
    if (
      /\bsupabase\s+(start|stop|db\s+(reset|push|pull|start|diff)|migration\b|link\b|seed\b|init\b)/.test(command) ||
      /\bpnpm\s+(run\s+)?supabase:(start|stop|reset|restart|link|push|pull|migration|seed)/.test(command) ||
      (/\bdocker\s+(run|create|compose\b[^|;&]*\bup)\b/.test(command) &&
        /postgres|pgvector|timescale|supabase/i.test(command)) ||
      /\bdocker\s+(exec|rm|stop|kill)\b[^|;&]*\bsupabase_[a-z_]+_swarms-shared\b/.test(command) ||
      /\bpsql\b[^|;&]*(54322|supabase_db_)/.test(command)
    ) {
      return {
        block: true,
        reason:
          "backend infrastructure is off-limits to a lane. ONE shared Supabase stack already " +
          "serves every worktree (API http://127.0.0.1:54321, Studio :54323, Mailpit :54324) and " +
          "your .env.local points at it - `pnpm dev` boots with no setup. Its database is a " +
          "read-only test fixture: no supabase start/stop/db reset, no migrations, no docker " +
          "postgres, no psql writes - ever. If the issue truly needs a schema or data change, " +
          "append `needs-decision [key=schema]: <what and why>` and stop. " +
          "Details: ~/oss-fleet/shared-supabase/README.md",
      };
    }

    return ALLOW;
  });
}

# Project guidelines

Codex CLI and Copilot CLI read this file. Claude Code does not — it reads
CLAUDE.md and `.claude/rules/`. The file matters even in a Claude-only project:
`/xreview` runs `codex exec` here, and AGENTS.md is the only channel that
carries project context into that cross-model review.

This project uses shared conventions: the rules in `.claude/rules/` and the
convention docs they point to. Those files are authoritative — read them when
relevant.

## Core references

- `.claude/rules/shared-config.md` §Guidelines — the convention docs with their
  paths: engineering principles, clean code, git rules, security, Spring,
  SvelteKit, database, E2E
- `.claude/rules/docker-safety.md` — container conventions
- `.claude/rules/shared-config.md` — MCP safety and fallback rules, config keys, story sizing, doc pointers
- `.claude/rules/git-commit.md` — stage new and changed files by name (never `git add -A`), short, why-focused commit messages, no co-author trailer
- `.claude/rules/story-writing.md` — story titles and `## Details` from the user's point of view

## Per-language rules (read when you touch that language)

Codex has no glob-scoped auto-application, so consult these by hand:

- `.claude/rules/java-best-practices.md` — Java (conventions, naming, tests)
- `.claude/rules/typescript-conventions.md` — TypeScript
- `.claude/rules/swift-best-practices.md` — Swift (conventions, naming, tests)
- `.claude/rules/flyway-migrations.md` — DB migrations

## Cross-review criteria (/xreview)

<!-- >>> claude-agents xreview criteria (generated - do not edit inside this block) >>> -->
Apply these criteria when you review code as an independent cross-model
reviewer — the `/xreview` command, or any `codex exec` review call.

Focus on the bugs that Claude-family models miss most often:

1. Off-by-one errors and boundary conditions in loops
2. Null handling: Java Optional misuse, Swift implicit unwraps, JS undefined vs null
3. Concurrency: Spring `@Transactional` propagation, SwiftUI `@MainActor` leakage, races in async/await
4. Reactivity: Svelte 5 `$state` vs legacy `$:`, effect timing
5. Authorization: missing `@PreAuthorize`, IDOR, broken object-level access
6. Test-coverage gaps: changed code with no matching test delta
7. Hidden side effects: changes to files that look unrelated to the task

Be brutally honest. Do not soften a severity to be polite. If a CRITICAL bug
exists, mark it CRITICAL.

Severity:

- **CRITICAL** — ship-blocker: data loss, security hole, broken auth, exception in the main flow
- **HIGH** — fix before merge: edge-case bug, test gap on a critical path, performance regression
- **MEDIUM** — address in a cleanup story: style, small refactor, missing nice-to-have test
- **LOW** — nit: omit unless you are very confident

The verdict is FAIL if one CRITICAL finding exists. Otherwise the verdict is PASS.
<!-- <<< claude-agents xreview criteria <<< -->

### Project stack

Java/Spring backend, SvelteKit frontend, Swift/SwiftUI iOS.

Replace that line with this project's stack. It sits outside the
generated block, so an install never overwrites it, and the
cross-review prompt has no other way to learn the stack.

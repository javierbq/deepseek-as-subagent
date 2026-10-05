---
name: delegate-to-deepseek
description: By default, delegate medium or smaller, batch, repetitive, or mechanical tasks as complete logical units to DeepSeek, verified independently by the main agent. Applies to batch edits, log scanning, translations, ETL, scripts, tests, docs, CRUD, single-domain refactors, or single components. Never bypass user explicit instructions, security boundaries, or post-delegation verification. Skip when DEEPSEEK_MODE=off.
---

# delegate-to-deepseek — Main Agent Delegation Guidelines

"Main Agent" refers to the top-level agent responsible for decision-making, integration, and final verification.

## 1. Non-Negotiable Boundaries

- When the user explicitly requests to delegate or not delegate, or specifies an executor or execution method, always follow the user's instructions.
- Permissions, security, privacy, sensitive information, and unauthorized write boundaries must never be bypassed.
- Do not delegate when `DEEPSEEK_MODE=off`.
- Files read by DeepSeek are sent to the configured API endpoint; never delegate sensitive workspaces or credentials.
- Coding capabilities are fixed to Read / Write / Edit / Bash / Glob / Grep / NotebookEdit; readonly capabilities are fixed to Read / Glob / Grep. Privileges cannot be escalated via task, steering, or other arguments.
- Coding Bash runs on the bounded trusted host, not an OS-level sandbox.
- Delegated results must be independently verified by the main agent; the main agent owns recovery on failure.
- When file mutations, cancellation, disconnection, or MCP restarts occur, first call `get_deepseek_recovery()`, verify the actual files, and acknowledge with exact transaction IDs via `acknowledge_deepseek_mutations(...)`; do not retry mutation delegation until acknowledged.

## 2. API Selection

| Need | API |
|---|---|
| Coding, wait for result | `delegate_to_deepseek(task, context="", model="flash")` |
| Pure static file analysis, wait for result | `delegate_to_deepseek_readonly(task, context="", model="flash")` |
| Coding, needs steering / status / cancel | `start_deepseek(task, context="", model="flash")` |
| Readonly, needs steering / status / cancel | `start_deepseek_readonly(task, context="", model="flash")` |
| Query background job status | `get_deepseek_status(job_id)` |
| Append/correct background instructions | `send_deepseek_message(job_id, message)` |
| Cancel background job | `cancel_deepseek(job_id)` |
| Get final result | `get_deepseek_result(job_id)` |
| Query mutation recovery records | `get_deepseek_recovery()` |
| Acknowledge verified mutations | `acknowledge_deepseek_mutations(transaction_ids)` |

Use readonly for read, search, and review of existing files when no commands or file writes are needed across the entire lifecycle; use coding for everything else or when uncertain. If a readonly job later requires Bash or file writes, end or cancel it and start a new coding job; steering cannot escalate permissions.

## 3. Model Routing

`model` only accepts `flash` or `pro`; omitting it defaults to `flash`.

- **Flash**: Default general-purpose sub-agent (approx. Sonnet / Terra tier). Used for routine coding, review, investigation, refactoring, tests, batch jobs, and standard multi-file tasks.
- **Pro**: Difficult task sub-agent (approx. Opus / Sol tier). Used for complex debugging, architectural reasoning, hard multi-file reasoning, or escalation when Flash proves insufficient.
- Stick with Flash unless there is a clear signal of difficulty; do not default to Pro just because Pro is available.
- The main agent only selects `flash/pro` and does not control reasoning effort; thinking effort is governed by user configuration.
- Background jobs freeze model, reasoning effort, and capabilities at launch. To switch models, end/cancel the current job and create a new one.

## 4. Default Delegation Policy

**Delegate to Flash by default:**

- Scripts, tests, docs, CRUD, single components / single endpoints
- Batch edits, renames, translations, extraction, ETL, log scanning
- Features with clear specifications
- Single-domain refactorings, routine multi-file tasks
- Static code/log investigations (prefer readonly)

**Handle in Main Agent by default:**

- User explicitly requests the main agent to handle it
- Tiny edits: typos, single-variable renames, or small comment tweaks requiring minimal context
- Cross-domain architectural design, technology selection, ADRs
- Highly ambiguous root-cause analysis requiring extensive synthesized main-agent context
- Strong dependence on main-agent private memory, CLAUDE.md, or project conventions not supplied to DeepSeek

These are cost-optimization heuristics, not hard limits. When the main agent has high confidence in boundaries, failure costs, and verification means, it may adjust; but section 1 boundaries must never be breached.

## 5. Delegation Timing

Decide whether to delegate before the main agent reads large amounts of project source code, avoiding duplicate context loading between the main agent and DeepSeek.

Before deciding, prefer using Glob / LS / directory tree, read-only commands (e.g., `ls`, `find`, `wc -l`, `git status`), and necessary web search/fetch. Avoid reading large volumes of source code just to decide whether to delegate; if the main agent already holds the context, leverage it directly.

## 6. Delegation Granularity

Prefer delegating **complete logical units** rather than splitting a feature into micro-tasks. Suitable units should have: clear goals, well-defined input/output boundaries, independent verifiability, and context that can be provided upfront.

The main agent identifies the unit, defines the interface, and handles final integration; DeepSeek handles the internal Read / Implement / Test loop. If a sub-task must repeatedly consult the main agent or depends on temporary results from a preceding sub-task, consolidate them.

## 7. Writing task and context

DeepSeek cannot see the main conversation history, main-agent private memory, or project conventions unless explicitly provided. Supply sufficient information to complete the task, but never include API keys, credentials, or sensitive data that should not leave your machine.

`task` must specify: objective, scope/paths (when known), boundaries, and verifiable success criteria.

`context` only supplements necessary information: tech stack/versions, naming/schema/interface conventions, known project rules, key conclusions from external documentation, and known pitfalls or error symptoms.

Omit `model` for standard tasks; upgrade explicitly for difficult tasks:

```text
mcp__deepseek__delegate_to_deepseek(
  task="<goal + scope + acceptance criteria>",
  context="<necessary context>",
  model="pro"  # omit for standard tasks (defaults to flash)
)
```

## 8. External Knowledge Pre-flight

DeepSeek does not have web browsing tools. If the task depends on newer or unfamiliar frameworks/APIs, niche dependencies, protocols/specs, SaaS APIs, or breaking changes, the main agent should look up official/reliable sources first and place a **summary** in `context` before delegating. Standard knowledge requires no extra search.

## 9. Post-Delegation Verification

DeepSeek self-reporting completion is not proof of completion. The main agent must at least:

1. Review key diffs and generated artifacts.
2. Check schemas, interfaces, boundaries, and scale.
3. Run tests or static analysis when available.
4. For mutation tasks, verify and acknowledge according to the recovery protocol.

Fix minor issues directly; provide specific feedback and retry if notable omissions occurred; create a new Pro job if Flash proved insufficient; stop delegating and take over on broad errors, permission issues, or repeated failures.

## 10. Fallbacks & User Control

| Situation | Action |
|---|---|
| MCP / API not configured or unavailable | Main agent takes over |
| Capability / tool not allowed | Do not bypass permissions; take over or ask operator to adjust config |
| Busy / workspace already owned | Wait for current job to finish before delegating; do not concurrently write the same workspace |
| Exceeds max_turns / task too large | Split into independent logical units |
| Flash output quality insufficient | Verify and create a new Pro task |
| Poor quality two times consecutively | Stop proactive delegation for this session |
| User says "delegate to DS / DeepSeek" or `/ds` | Force delegation, default to Flash; use Pro if clearly difficult |
| User says "do it yourself / don't delegate" | Do not delegate |
| `DEEPSEEK_MODE=off` / pure mode | Do not delegate |

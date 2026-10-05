---
description: Explicitly delegate a task to the DeepSeek sub-agent (bypassing Claude's automatic decision). Usage: /ds <task description>
---

# /ds — Delegate to DeepSeek

Forces delegation of the subsequent task to DeepSeek, bypassing Claude's auto-decision ("should delegate / shouldn't delegate").
`/ds` always calls the full coding API; tasks that are explicitly static file analysis should use `delegate_to_deepseek_readonly`.

Model selection follows the `delegate-to-deepseek` skill: omitting `model` defaults to Flash; only specify `model="pro"` if the task clearly involves complex debugging, architectural reasoning, difficult multi-file reasoning, or when Flash was insufficient. Flash roughly corresponds to Sonnet/Terra tier, Pro roughly corresponds to Opus/Sol tier; this is a routing guideline, not an absolute claim.

`flash/pro` are stable routing slots. Do not pass real provider model IDs into the MCP tool; the actual model IDs are configured in `~/.deepseek-mcp/config.json`.

## What you must do:

1. Prepare `task`, `context`, and optional `model` according to the `delegate-to-deepseek` skill guidelines:
   - Collect relevant file paths using Glob / LS.
   - Summarize project conventions (naming rules, output schemas, boundaries).
   - State clear, verifiable success criteria.
   - Keep default Flash for normal tasks; choose Pro only for difficult tasks.

2. Call the `mcp__deepseek__delegate_to_deepseek` tool, passing the user request as the task:

```
User input: $ARGUMENTS
```

3. Once the tool returns, you MUST verify:
   - Sample output files with Read.
   - Check schema sanity and counts.
   - Handle failures using the skill's fallback strategy.

## What NOT to do:

- ❌ Do NOT ask the user "Are you sure you want to delegate?" before calling (typing `/ds` is already an explicit instruction).
- ❌ Do NOT default to Pro just because Pro is available.
- ❌ Do NOT pass provider model IDs to the `model` parameter.
- ❌ Do NOT give up immediately if the tool returns an ERROR — follow the fallback strategy to retry or take over.
- ❌ Do NOT put API keys or credentials in task or context.

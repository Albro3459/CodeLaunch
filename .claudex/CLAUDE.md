# Claudex profile

This is the GPT-backed Claude Code profile. Requests route through CLIProxyAPI
(`ANTHROPIC_BASE_URL=http://127.0.0.1:8317`) to a ChatGPT/Codex subscription.
The Claude model roles are remapped to GPT models by the proxy environment:

- `fable`  -> GPT-5.6 Sol
- `opus`   -> GPT-5.6 Luna
- `sonnet` -> GPT-5.5
- `haiku`  -> GPT-5.4 mini

The primary model for this profile is GPT-5.6 Luna (the `opus` role).

## Delegation

Available GPT-named agents (invoke with `@agent-<name>`):

- `gpt-5-6-sol`   — OpenAI's model for flagship capability
- `gpt-5-6-luna`  — efficient, high-volume workloads
- `gpt-5-5`       — a new class of intelligence for coding and professional work
- `gpt-5-4-mini`  — strongest mini model for coding, computer use, and subagents

Route by capability: hardest reasoning to `gpt-5-6-sol`, high-volume or
low-latency work to `gpt-5-4-mini`, coding and professional work to `gpt-5-5`.
Each agent's `model` frontmatter stays a supported Claude role so the proxy
performs the translation.

## Effort

Effort baselines are set at the proxy per model (high for Sol/Luna, medium for
GPT-5.5 and 5.4 mini) and only fill when the request omits an effort, so a
subagent's `effort` frontmatter or an explicit `/effort` choice still wins.

## Shared rules

@/../.claude/CLAUDE.md

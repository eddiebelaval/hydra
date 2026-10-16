# Hydra LLM Gateway

Started 2026-10-14, after one API spend cap took out every metered Hydra job
for two days (observer, reflector, brain-updater, ava-memory-compiler,
journey-append, Milo heartbeat) with no alert, no meter, and a retry every
15-30 minutes until the reset.

## The rule

Every model call goes through one door: `~/.hydra/lib/hydra_llm.py`
(Python: `complete(...)`, shell: `~/.hydra/bin/hydra-llm`). A job names a
TASK and a TIER, never a model ID. The gateway picks the lane.

## Lanes (cheapest adequate first)

| Lane | Serves | Billing | Status |
|------|--------|---------|--------|
| 0 code | gates before any call (see Milo `shouldFire`) | free | caller's job |
| 1 subq | `decide` only: classify, yes/no, score | SubQ Snap, ~$0.05/M input | OFF until key in Keychain + ZDR answer |
| 2 sub | summarize, extract, write (batch) | id8labs subscription via `claude -p` | ON |
| 3 api | chat (live, latency-bound) | metered key (Keychain `id8-automation-api-key`) | ON, last resort for batch |

Task -> lane order lives in `config/llm.json` (`tasks`). Tier -> model per
lane lives in the same file (`tiers`). Changing a model is a one-line edit.

## What the gateway owns

- **Meter.** Every attempt is a row in `hydra.db` table `llm_calls`
  (job, task, lane, model, tokens, cost-equivalent USD, status, ms, error).
  `hydra-llm report` prints today/7d by job and lane.
- **Breaker.** Per lane, in `state/llm-breaker.json`. A usage-limit error
  opens the lane until the reset time the API names; a rate limit opens it
  30 minutes; 5 straight errors open it 60 minutes. Open lanes are skipped
  (falls through to the next lane). One Telegram alert per opening, never
  one per failure.
- **Budget.** Calls per job per day (`budgets`). Over budget = quiet skip
  plus one alert per job per day.
- **Quiet skip.** When no lane can serve, `complete()` raises `Skipped`
  and the CLI exits 75 (EX_TEMPFAIL). Callers log one line and exit 0.

## Subscription lane details

`claude -p --model <alias> --output-format json --system-prompt ... --tools ""
--strict-mcp-config --setting-sources "" --no-session-persistence`, run in an
empty temp dir with `ANTHROPIC_API_KEY` unset and `CLAUDE_CONFIG_DIR` set
from `~/.claude/id8labs-sub.env` rules (falls back to the default profile,
loudly, when the id8labs login is EXPIRED). No tools, no hooks, no MCP, no
CLAUDE.md: about 650 tokens of overhead per call. Measured 2026-10-14:
2.5 s round trip on haiku.

Shares rate limits with Eddie's interactive sessions on the same account,
so batch jobs stay off-peak and the meter shows any crowding.

## Plan

| Phase | Work | Gate |
|-------|------|------|
| 1 | Gateway core, meter, breaker, budgets, bats tests | DONE 10/14 |
| 1 | Move observer, reflector, brain-updater, ava-memory-compiler, journey-append onto it | DONE 10/14 |
| 2 | Lexicon transcript ingest (`scripts/stream.ts`): `deriveText` routes through the gateway when `LEXICON_LLM_GATEWAY=1` (set by the local runner only; Vercel keeps the SDK) | DONE 10/15 |
| 2 | Milo heartbeat, summarize, extract-memories, reclassify (`gatewayMessages` in llm-gateway.ts) | DONE 10/14-15 |
| 2 | morning-planner, life-delta-engine, mara-poster, ava-memory-sync, telegram-ingest-kb, planning/review reply handlers, natural parser, both Telegram listeners (urllib drop-in: `hydra_llm.Request` / `hydra_llm.urlopen`) | DONE 10/15 |

| 3 | SubQ lane wired from docs.subq.ai, shadow on hydra-router classifier for 2 weeks | Eddie: SubQ key in Keychain + ZDR form |
| 4 | Collapse overlap: four Telegram front doors, six memory compressors | Eddie: review the merge map |
| 5 | Retire every hard-coded model ID: `config/llm.json` is the only place one lives; gate = `hydra-llm lint-models` (bats test 11) | DONE 10/16 |

Still on the raw key, by design: Milo chat and hydra-router chat (tool loops
the subscription lane cannot run), the router's classifier (SubQ phase-3
shadow target), Ava's photo reader (images), and `hydra-heartbeat`'s API
health ping (it measures the API itself).

## Picking a model (phase 5)

No Hydra code names a model ID. Gateway callers name a tier; an old
urllib payload's `"model"` field may say `haiku` / `sonnet` / `opus`, which
only picks the tier. Callers that must reach a model themselves resolve it:

- shell: `"$("$HOME/.hydra/bin/hydra-llm" model mid --lane sub)"`
- Python: `from hydra_llm import model_for; model_for("mid")`
- TS: `modelFor('mid')` (milo-respond `llm-gateway.ts`, hydra-router `llm-models.ts`)

Both lanes are pinned to exact IDs (an unattended 3am job must not float onto
a new model through an alias). Upgrading a tier is one edit in `config/llm.json`.

## Eddie's gates

1. id8labs subscription login. DONE 10/16 (eb@id8labs.tech, Max). The browser
   login expires; to end re-logins, mint a long-lived token once:
   `CLAUDE_CONFIG_DIR=~/.claude-id8labs claude setup-token`, sign in as
   id8labs, copy the token it prints, then TYPE `~/.hydra/bin/id8-token`
   (validates, strips the wrap line break, stores, proves it; DONE 10/16). Manual equivalent:
   `security add-generic-password -U -a hydra -s claude-id8labs-oauth-token -w "$(pbpaste)"`.
   The gateway, `id8labs-sub.env` and the 2-hourly probe all read it from
   Keychain. While the profile is expired the probe alerts once a day.
2. API cap (money): only live chat needs the metered key after phase 1.
3. SubQ key: `security add-generic-password -U -a hydra -s subq-api-key -w "$(pbpaste)"`, plus the ZDR form.

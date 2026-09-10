# shuvbro fork boundary

This repository is a maintained fork of [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate).
Canonical product identity is **shuvbro**.
Compatibility identifiers from upstream stay at their original bytes.
`bin/fm-fork-boundary-check.sh` is the executable form of this contract.

## Provenance

- Upstream: `https://github.com/kunchenguid/firstmate`
- Upstream revision this fork started from: `269f8fe64a692ebdabd7c9ad205f5aa5c28caadc` (`269f8fe`, `main`)
- Public destination: `https://github.com/shuv1337/shuvbro`
- License: MIT, copyright notice for Kun Chen preserved in `LICENSE`
- Local remotes: `origin` → `shuv1337/shuvbro`. There is no `upstream` remote; do not write to the firstmate repository.

Future upstream merges are expected as deliberate cherry-picks or reviewed merges onto this fork.
Do not write to upstream.
Do not treat an upstream fast-forward as a product-identity reset.

This is a clone-and-run agent distro.
There is no invented binary, package, or build step.

## Canonical identity

Rename these on product surfaces:

| Surface | Canonical value |
|---|---|
| Product | `shuvbro` |
| Public repository | `github.com/shuv1337/shuvbro` |
| Default lead display name | `Bro` |
| Default user display name | `dude` |
| Default worker / specialist / investigation / queue labels | `worker`, `specialist`, `investigation`, `queue` |
| Default tone | informal and candid; no mandatory address; no forced slang |
| Neutral preset | operational ids as display names; no flavor |
| dzl preset | opt-in Jersey Shore-inspired presentation; identifiable role names; optional verified-ready opener `AYO, PR'S HERE` |

`AGENTS.md` uses operational role ids (`lead`, `user`, `worker`, `specialist`, `investigation`, `queue`) and defers display names and tone to the `PERSONA` block emitted at session start.
`GROK_BOT.md` is a canonical standalone persona surface for the Grok bot product and follows the same default Bro presentation.

`assets/banner.png` is unlinked upstream artwork kept in the tree as a historical file.
It is not current shuvbro branding, and README does not reference it.

## Compatibility (preserve byte-for-byte)

Do not rename these, and do not add `SB_` aliases:

- `FM_*` environment variables, including `FM_HOME`, `FM_INJECT_MARK`, and every other `FM_` contract
- `bin/fm-*` automation paths
- `FIRSTMATE_OP:` operational-input prefix (`bin/fm-operational-input.sh`)
- `fm-main-mirror` customType
- Stored filenames `data/captain.md` and `data/captain-shared.md`
- Mirror tags `[captain]` and `[main]`
- Verdict JSON `captain` / `routine`
- Skill directory names and slash commands (`/updatefirstmate`, `/afk`, `/bearings`, `/stow`, `/ahoy`, `firstmate-coding-guidelines`, `stuck-crewmate-recovery`, `captain-hold-lifecycle`, and the rest of the tracked skill tree)
- Tracked `.tasks.toml`
- Parsed brief headings `## Captain's intent` and `## Firstmate spec` (exact ASCII, including the apostrophe in Captain's)
- Placeholder `{FIRSTMATE_SPEC}`
- `.no-mistakes.yaml` `disable_project_settings: true`
- Status protocol text owned by `bin/fm-watch.sh` and `bin/fm-captain-hold.sh`
- Relay identifiers (`FMX_`, `x-`, `fm-x-`)
- `[fm-from-firstmate]` routing marker

Review, merge, and safety authority stay unchanged.
The no-mistakes-required contributor workflow and `CONTRIBUTING.md` review mandate stay in force.
Fork URLs are canonical; this fork does not write to upstream.

## Persona presentation

Role names and tone are presentation only.
They cannot alter safety, approvals, protocols, or success truth.

Authoritative file: gitignored `config/persona` under the effective home.
Schema owner: [`docs/configuration.md`](configuration.md) "Persona".
Resolver owner: `bin/fm-persona-lib.sh`.

- Absent file: built-in `bro` default.
- Present file: must validate; invalid explicit config returns an error and never falls back to neutral or default.
- Inheritance: primary-authoritative through `FM_INHERITABLE_CONFIG` in `bin/fm-config-inherit-lib.sh`, the same owner as other inherited local config.
- Independent `FM_HOME` values that are not in a primary→secondmate relationship keep separate persona files.
- Present-file byte validation uses perl, already required by other `bin/` scripts; python3 is not a universal prerequisite and is not used here.

Flavor is restricted to user-facing messaging.
Commits, reviews, and machine output stay plain.
The dzl success opener is allowed only for a verified ready PR outcome, never for pending or failing work.
Serious failures, security questions, and approval asks stay plain in every preset.

## Remaining-name inventory

`bin/fm-fork-boundary-check.sh` classifies every tracked path that still matches `firstmate`, `kunchenguid/firstmate`, or spaced `first mate`.
This is a path classification, not a semantic per-match audit of every remaining token.
There is no leftover/fallback class: an unmatched path fails the check.
Loaded skill files (`.agents/skills/*/SKILL.md`) are scanned for literal mandatory captain-address and nautical-seasoning patterns.
Those patterns are string safeguards, not exhaustive semantic proof that every remaining `captain` or `firstmate` token is correctly classified.
Protocol nouns such as `captain-hold`, `captains_call`, and `## Captain's intent` are not banned.
New `docs/*.md` files outside an allowlist cannot reintroduce the upstream clone URL or mandatory captain address.

| Class | Paths | Why the old name remains |
|---|---|---|
| `canonical-or-schema` | `AGENTS.md`, `README.md`, `VISION.md`, `GROK_BOT.md`, `CONTRIBUTING.md`, `docs/fork-boundary.md`, `docs/configuration.md` | Product copy plus explicit upstream/schema mentions |
| `provenance-asset` | `LICENSE`, `assets/*` | License notice and unlinked historical banner file |
| `historical-verification` | `docs/verification/*` | Dated evidence; do not rewrite historical claims |
| `test` | `tests/*` | Fixtures and assertions, including compatibility protocol strings |
| `implementation` | `bin/*`, `.pi/*`, `.omp/*`, `.claude/*`, `.cursor/*`, `.codex/*`, `.grok/*`, `.opencode/*` | `FM_*` / `bin/fm-*` automation and comments around those contracts |
| `compatibility-skill` | `.agents/skills/firstmate-*/*`, `.agents/skills/updatefirstmate/*` | Skill directory and slash-command names |
| `loaded-instruction` | other `.agents/skills/*` | Loaded skills; must not mandate captain address or nautical seasoning |
| `public-skill` | `skills/*` | Installer-facing skills that may mention upstream |
| `docs` | other `docs/*` | Operator/architecture docs; protocol filenames stay |
| `ci-or-config` | `.github/*`, `.greptile/*`, `.no-mistakes.yaml`, `.tasks.toml` | CI and tracked config |

Loaded/emitted instruction paths (`AGENTS.md`, `GROK_BOT.md`, `VISION.md`, `README.md`, brief/dod/branch/supervision/session-start generators) must not contain mandatory captain address or nautical seasoning policy.

The check also asserts these compatibility identifiers exist: `FM_HOME`, `{FIRSTMATE_SPEC}`, `FIRSTMATE_OP:`, `FM_INJECT_MARK`, `[fm-from-firstmate]`, `fm-main-mirror`, `[captain]`/`[main]`, verdict `captain`, `## Captain's intent`, `## Firstmate spec`, `data/captain.md`, `captain-shared.md`, `FMX_`/`fm-x-`, and the skill/slash names listed above.
It refuses `bin/sb-*` filenames and `SB_*` identifiers in `bin/` scripts.

## Private material

`data/`, `state/`, `config/`, `projects/`, `.env`, and `.no-mistakes/` are gitignored captain-private paths.
They must not be tracked.
This fork was cloned from tracked history only.

## Cherry-pick policy

Prefer cherry-picking or merging reviewed upstream commits that do not reassert upstream product identity on canonical surfaces.
After each upstream absorption, run `bin/fm-fork-boundary-check.sh` so a merge cannot silently restore mandatory captain address, upstream clone URLs, or a renamed compatibility identifier.

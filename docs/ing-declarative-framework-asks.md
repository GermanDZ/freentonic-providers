# Framework asks: making ING fully declarative

*From the provider authors, to the freentonic team.*

ING is the last provider carrying an `extractor.rb`. This doc explains
exactly which framework capabilities are missing, why each one is the
right home for the behavior, and what the end state looks like. Every
ask extends a primitive that already exists — none of this is new
architecture.

## Where the program stands

*Status re-audited against freentonic main @ `cfda5fa` (PR #37 merged,
2026-07-05). **Asks 0–5 have ALL shipped**: PR #35 (Ask 0 forward + Ask
1 endpoint headers/PUT), PR #36 (Asks 2–4, the `elevate:` phase), PR
#37 (Ask 5 plan verbs). This doc is kept as the program record; the
remaining gap for full ING retirement is Ask 6 at the bottom.*

| Provider | Extract | Blocked on |
| --- | --- | --- |
| Revolut | `extract: plan:` (on main) | — |
| Fintonic | `extract: plan:` (on main) | — |
| Unicaja | `extract: plan:` (on main) | — |
| **ING** | slim `extractor.rb` (orchestration only; SCA now in `elevate:`) | **Ask 6** |

The insight that unlocked this: **everything imperative left in ING is
session lifecycle, not extraction.** The extractor used to be four jobs
in one file — preflight diagnostics, SCA elevation + Bearer rotation,
fetch orchestration, and shape translation. Providers PR #28 already
moved shape translation to the normalizer (extractor now attaches raw
`/search` rows verbatim). What remains splits cleanly into "session
management" (asks 1–4) and "orchestration" (ask 5).

## Ask 1 — request headers on endpoint declarations

**Gap.** `define_get`/`define_post` accept `base:`, `params:`,
`pagination:`, `response_extract_batch:` — but no request headers. The
two SCA handshake calls are the only reason `client.raw_request` still
exists in any provider:

```ruby
# ing/extractor.rb — the whole raw_request surface:
client.raw_request(method: :get,  path: "/genoma_api/rest/sca/documentation",
                   headers: { "x-ing-reset-validations" => "1" },          # static
                   base: "https://ing.ingdirect.es")
client.raw_request(method: :put,  path: "/genoma_api/rest/sca/documentation",
                   headers: { "x-ing-securityprocessid" => process_id },   # per-call
                   body: { "processId" => process_id },
                   base: "https://ing.ingdirect.es")
```

**Ask.** Two additions to the endpoint YAML:

```yaml
- name: sca_documentation_challenge
  method: GET
  path: "/genoma_api/rest/sca/documentation"
  base: "https://ing.ingdirect.es"          # already supported
  headers:                                   # NEW: static headers
    x-ing-reset-validations: "1"
- name: sca_documentation_commit
  method: PUT                                # NEW: PUT verb if not present
  path: "/genoma_api/rest/sca/documentation"
  base: "https://ing.ingdirect.es"
  headers:
    x-ing-securityprocessid: "{process_id}"  # NEW: templated from kwargs
  json:
    processId: "{process_id}"
```

With this, `raw_request` disappears from providers entirely and the SCA
endpoints become `--lint`-checkable like everything else.

## Ask 2 — `await_operator_approval` step

**Gap.** The browser workflow grammar already has
`await_external_approval` (message / wait condition / timeout) — Revolut
uses it for push-2FA at login. ING needs the same *pause for a human*
mid-API-flow: trigger the SCA push, wait for the operator to approve on
their phone, continue.

**Ask.** An API-side step that wraps the existing prompt-store
primitive — the interface already matches exactly:

```ruby
# lib/freentonic/remote_prompt_store.rb — exists today:
def prompt(kind:, message:, mask: false, timeout_seconds:, until_satisfied: nil)
```

```yaml
- await_operator_approval:
    message: "ING is requesting SCA to release older history. Approve on your phone. (challenge: {challenge.acceptanceMethods.0.code})"
    timeout: 180
```

Semantics: prompt-store absent or timeout → the step *fails* (feeding
the `on_failure:` policy of ask 4), never hangs headless runs.

## Ask 3 — `rebind_credential:` (declared credential data-flow)

**Gap.** After SCA, ING mints a high-LoA Bearer and the extractor
installs it imperatively:

```ruby
client.update_auth_headers!({ "Authorization" => "Bearer #{new_bearer}" },
                            host: "api.ing.ingdirect.es")
```

`update_auth_headers!` is an arbitrary mutation — but what ING actually
does is fully constrained: *one dotted path from one declared endpoint's
response becomes one named header on one named host.* That's
`derived_credentials` (which exists) running in reverse.

**Ask.** Declare it as data-flow:

```yaml
- fetch: refresh_access_token          # already a declared endpoint
  as: refreshed
- rebind_credential:
    header: Authorization
    host: api.ing.ingdirect.es
    value: "Bearer {refreshed.accessTokens.0.accessToken}"
```

Lint can verify the source binding exists, the host appears in the
`auth_headers` host-scoped blocks, and nothing else is touchable. This
is *more* auditable than the Ruby, not less: today ING's rotation powers
are discoverable only by reading the extractor; here they're four lines
of YAML. If the templated value resolves empty/nil, the step fails
(→ `on_failure:` policy) rather than installing a broken header.

## Ask 4 — an `elevate:` phase (composition of 1–3)

**Gap.** Nowhere declarative to *put* the handshake. It isn't extraction
(it mutates session state) and it isn't login (it's conditional on the
requested lookback). It's a third lifecycle moment: session elevation.

**Ask.** A workflow section that runs between connect and extract:

```yaml
elevate:
  when: { lookback_days_gt: 90 }    # Phase-2 `when:` + `lookback_days` seed binding
  on_failure: degrade               # warn + continue with the captured Bearer
  steps:
    - fetch: sca_documentation_challenge
      as: challenge
    - await_operator_approval:
        message: "ING is requesting SCA… approve on your phone."
        timeout: 180
    - fetch: sca_documentation_commit
      args: { process_id: "{challenge.acceptanceMethods.0.securityProcessId}" }
    - fetch: refresh_access_token
      as: refreshed
    - rebind_credential:
        header: Authorization
        host: api.ing.ingdirect.es
        value: "Bearer {refreshed.accessTokens.0.accessToken}"
```

The `on_failure: degrade` policy is load-bearing — it encodes ING's
current behavior matrix verbatim (extractor header comment): SCA
timeout, missing processId, or empty refreshed token all warn and
continue with the low-LoA Bearer (history truncates at ~90d). `abort`
should also exist for providers where elevation is mandatory. The
steps interpreter is the *same* one as `extract: plan:` — same scope,
same templates, same linter — plus the two new step kinds.

## Ask 5 — three small plan verbs for the remaining extract

Once 1–4 land, ING's extract is pure orchestration except for three
idioms the current grammar can't express:

1. **`index_by:` / find-by-field** — the V1ID→UUID map walks
   `products[].identifiers[]` picking `type == "LOCAL_UUID"` /
   `type == "UUID"` values into a lookup hash (`build_uuid_map`).
   Pure shape work: index a list into a map by extracted keys.
2. **Skip-with-warning routing** — per-product: investment → skip
   loudly (a single investment UUID 401-poisons a multi-UUID batch),
   loan → balance-only, missing v2 UUID → warn + skip. Needs
   `skip_when:` + a `warn:`/`note:` message verb so operators keep
   today's breadcrumbs. The kind lookup itself is data we already ship
   (`kind_by_product_type` in `ing/config.yml`).
3. **Fatal fetch with a custom message** — `/position-keeping` failure
   must abort with an operator-actionable message (a 0-product payload
   would read downstream as "all accounts deleted"). Something like
   `on_error: { abort: "ING extract: /position-keeping failed… re-run after a fresh login." }`.
   The same verb covers the two preflight checks (Bearer captured →
   abort; XSRF cookie present → warn only).

## What we are NOT asking for

- **No `ruby_step:` escape hatch.** Considered and rejected: it would
  reintroduce the audited-Ruby surface inside YAML and every borderline
  provider would reach for it.
- **No computing verbs.** The guardrail we've been applying: plan verbs
  may *filter, dig, index, and guard*; the moment a verb computes
  (arithmetic, string surgery beyond `{templates}`), that work belongs
  in the normalizer. ING's remaining computation (amount coercion, date
  reformat, v2-seq id synthesis) already moved there in providers #28.

## Ask 6 — the one idiom Ask 5 turned out not to cover: a dynamic-key lookup

Migrating against PR #37 surfaced a gap none of us spotted in the Ask 5
design: **nothing in the grammar can read a map with a runtime key, or
compare two bindings.** ING's remaining extract needs exactly that once,
at its heart — the legacy↔modern product join:

```ruby
# extractor.rb — the join Ask 5 can't express:
v2_uuid = uuid_map[product["uuid"]]     # dynamic-key map read
```

`index_by:` *builds* the map (works great), but nothing reads it back:
`select:`'s `path:` is a static string, and a `when:`/`skip_when:` gate
compares a binding against a *literal* operand, never against another
binding. Without the join, a plan can iterate legacy products (which
carry `type` for kind routing but no v2 UUID) or modern products (which
carry identifiers but no `type`) — never both.

**Ask.** One verb, same filter/dig/index/guard altitude as the rest:

```yaml
- lookup: { from: uuid_map, key: "{product.uuid}" }   # template-resolved key
  as: v2_uuid
```

With it, ING's remaining extract is fully expressible: per-product
`lookup:` → `warn:`+`skip_when:` on `v2_uuid` absent → routing
`skip_when:` on the type ints from `kind_by_product_type` → per-UUID
`fetch:` with `on_error`.

Two smaller residues we propose to simply accept rather than grow verbs
for, when the final migration happens:

- **Credential preflights.** The Bearer-missing abort collapses into
  `/position-keeping`'s `on_error: { abort: }` message (same operator
  outcome, one wasted HTTP call). The XSRF-cookie warning (a regex over
  a captured credential) moves to the normalizer or is dropped —
  credentials are deliberately not in plan scope, and we are not asking
  for that.
- **Unknown-type whitelist.** The old extractor skipped product types
  absent from `kind_by_product_type`. Gates can't express "not in
  set"; enumerating the known-bad types (1, 42, 77) as `skip_when:`
  steps is equivalent today and fails open (fetches, `safe:`-degraded)
  for genuinely new types — acceptable, and loud in the run log.

## Sequencing

1. ~~freentonic PR #32 (base `extract: plan:` grammar)~~ — **done**, on
   main (`f1137f2`) with the grammar reference at `docs/extract-plan.md`.
2. ~~**Ask 0** — forward the stranded PR #33 verbs to main~~ — **done**,
   freentonic PR #35; the Fintonic + Unicaja plans are on providers main.
3. ~~**Asks 1–4** (endpoint headers, `await_operator_approval`,
   `rebind_credential:`, `elevate:` phase)~~ — **done**, freentonic PRs
   #35 + #36. ING's SCA handshake is now the `elevate:` block in
   `ing/workflow.yml`; `raw_request` and `update_auth_headers!` are gone
   from every provider.
4. ~~**Ask 5** (index_by, skip-with-warn, on_error message)~~ — **done**,
   freentonic PR #37.
5. **Ask 6** (`lookup:` — dynamic-key map read) — after which
   `ing/extractor.rb` is deleted and every provider in this repo is
   zero-Ruby except normalizers. The final migration also moves the
   movements-to-product attachment behind a raw-shape decision: either
   `lookup:` keeps today's shape (movements attached per product), or
   the plan outputs `movements_by_uuid` and the normalizer joins.

End state: the only Ruby a provider PR can contain is a normalizer, and
everything a provider is *allowed to do* to a session is enumerable by
grepping its `workflow.yml`.

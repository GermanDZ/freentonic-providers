# Writing extract plans

Every provider's extraction is an `extract: plan:` block in `workflow.yml`:
call the declared endpoints, loop over the rows, call another endpoint per
row, assemble the raw hash — **zero extractor Ruby**. A Ruby
`extractor.rb` (`extract: ruby:`) is refused at run start by freentonic ≥
0.18.0 unless `FREENTONIC_ALLOW_PROVIDER_RUBY=1` is set, and production
servers don't set it.

This is the provider-author playbook. For the full grammar reference see
the framework's
[docs/extract-plan.md](https://github.com/GermanDZ/freentonic/blob/main/docs/extract-plan.md);
this doc covers what a plan can express, the grammar in one screen, and
how to migrate a legacy `extractor.rb`.

## TL;DR

```yaml
# Legacy — extractor.rb + this in workflow.yml (refused by default):
extract:
  ruby: ./extractor.rb
  class: Freentonic::Providers::MyBank::Extractor

# Now — no extractor.rb, just this:
extract:
  plan:
    steps:
      - fetch: fetch_accounts
        as: accounts
      - for_each:
          source: accounts
        as_item: account
        as: movements
        collect: map
        key: "{account.id}"
        do:
          - fetch: fetch_movements
            args: { account_id: "{account.id}", from_date: "{from_date}" }
            as: rows
            safe: true
            default: []
          - yield: "{rows}"
    output:
      accounts: "{accounts}"
      movements: "{movements}"
```

This is the same plan worked through in
[creating-a-provider.md § 3](creating-a-provider.md#3-write-the-extract-plan).

## What a plan can express

A plan:

- calls endpoints declared in your `api_client:` block (pagination is
  declared on the endpoint),
- loops over a response's rows to drive per-row calls,
- digs sub-values out of responses (a field, a nested field, a
  first-present fallback), joins lists (`index_by:` / `lookup:`), merges
  and dedups (`concat:`, `dedup_by:`),
- gates steps on the lookback or on what came back (`when:`), warns or
  aborts with an operator message,
- applies registered pure functions (`apply:`) for per-row computation,
- reads browser-captured data through a top-level `captured:` block, for
  a provider with no usable API (`n26/`).

What it deliberately can't do — `raw_request` to an undeclared endpoint,
arbitrary Ruby, mid-run auth rotation from inside the plan — is not a
reason to write an `extractor.rb`. Look for the framework feature that
covers it first: an SCA handshake with operator approval and a Bearer
rebind is the declarative `elevate:` phase (ING). If nothing does, it's a
framework gap to raise upstream (see `AGENTS.md`, "Proposing new
framework capabilities").

All five providers here extract with a plan: **Revolut**, **Fintonic**,
**Unicaja**, **ING** (with an `elevate:` phase for SCA) and **N26**
(capture-only).

> Fintonic and Unicaja used to sit in between — a coalesced date range, a
> read/unread merge+dedup (Fintonic), and a conditional extended-history
> fetch with a cross-field dedup (Unicaja). The Phase-2 verbs (`let:` +
> `coalesce:`, `concat:`, `dedup_by:`, and the `when:` gate) cover exactly
> those, so both are now `extract: plan:`. What stayed out of the grammar:
> Unicaja's credit-vs-debit **string** filter — that classify-and-drop
> lives in Unicaja's normalize plan (a `skip_when:` on the card type),
> because it's a property of the account, not of what to fetch.

## The grammar in one screen

A plan is `steps:` (run in order) then `output:` (the assembled hash).
Every `as:` binds a name; later steps and `output:` reference it as
`{name}`. Three names are pre-bound: `from_date` (a Date), `from_ms`, and
`now_ms` (epoch milliseconds).

| Step | Does |
| --- | --- |
| `fetch: <endpoint>` | call a **declared** endpoint. `args:` (kwargs), `as:` (bind result), `safe: true` (tolerate failure → `default:`/nil), `extract_batch: [k]` (unwrap a hash-wrapped array). |
| `select: { from:, path:, default: }` | dig a sub-value out of a bound result. `path:` is a key, a dotted path (`meta.iban`), or a list (first non-nil wins). |
| `for_each:` | loop `source:` (a bound collection), each item bound to `as_item:`, running `do:` sub-steps, collecting each `yield:` into `as:`. `collect: map` + `key:` for a hash; default is an array. `pluck:`/`compact:`/`uniq:` shape the source list. |
| `yield: <value>` | (inside `do:`) the value collected this iteration. `skip_if_nil: <name>` drops the iteration when that binding is nil. |
| `let: <name>` | bind a value: `value:` (a template), `coalesce:` (first non-nil of a list — the declarative `a \|\| b \|\| "lit"`), or `days_ago: N` (`today - N`). |
| `concat: [a, b]` | bind `as:` to the merge of bound arrays (each `Array()`-coerced, so a gated-off name adds `[]`). |
| `dedup_by: key \| [keys]` | bind `as:` to `from:` deduped, first-wins; a fallback key list handles cross-endpoint field spellings; a **nil key is always kept**. |
| `when: { binding: { op: operand } }` | gate ANY step. False → the step is a no-op. Operators are the same as browser-phase `when_context:` (`gt`/`gte`/`lt`/`lte` numeric, `eq`/`neq`, `present`/`absent`). |

**Templates:** a string is a token only if it's exactly `{name}` or
`{name.dotted.path}` — everything else is a literal. `{account.id}` digs
into the bound `account` hash. Numbers, booleans, and nested
hashes/arrays in `args:`/`yield:`/`output:` pass through resolved.

Two more pre-bound names beyond `from_date`/`from_ms`/`now_ms`: `today` (a
Date) and `lookback_days` (`today - from_date`, the figure a `when:` gate
tests to toggle an extended-history fetch).

## Migrating a legacy `extractor.rb`

No provider in this repo has one any more; this is for porting one from
elsewhere.

1. **Capture a baseline.** With your current `extractor.rb`, run a real
   sync (or `--from-raw` off a saved response) and dump the raw payload:

   ```sh
   freentonic --workflow my_bank/workflow.yml --dump-raw /tmp/before.json ...
   ```

2. **Translate the orchestration.** Map each piece of `call(...)`:
   - `client.fetch_x` → a `fetch:` step.
   - `arr.each do |row| ... end` → a `for_each:` with `as_item: row`.
   - `row["a"] || row["b"]` → `select: { path: [a, b] }` or a `pluck:`.
   - `safe_fetch(stderr, …) { … }` → `safe: true` on the fetch.
   - the returned hash → `output:`.
   Keyed side-hashes (`movements_by_id[id] = …`) → `collect: map` +
   `key:`. Nested-in-place (`account["movements"] = …`) is fine too — just
   assemble the shape your normalizer already expects in `output:`.

3. **Swap the YAML.** Replace `extract: { ruby:, class: }` with your
   `extract: plan:`. Delete `extractor.rb`.

4. **Lint — it's fully static now.** `--lint` (no Chrome, no network)
   catches a typo'd endpoint or a dangling `{name}` before you log in:

   ```sh
   freentonic --workflow my_bank/workflow.yml --lint
   ```

5. **Prove equivalence.** Dump raw again and diff:

   ```sh
   freentonic --workflow my_bank/workflow.yml --dump-raw /tmp/after.json ...
   diff <(jq -S . /tmp/before.json) <(jq -S . /tmp/after.json)
   ```

   Empty diff → your normalizer and tests need no changes.

## Gotchas

- **`safe:` is not a session-death mask.** It rescues a failed
  *non-critical* fetch (one dead product), but a `SessionExpired`
  (401/403) always propagates so the run aborts with "re-run connect."
  Don't wrap the call that would reveal a dead session in `safe:` hoping
  to get a partial payload.
- **`fetch:` can only name a declared endpoint.** If you catch yourself
  wanting `raw_request` or a method that isn't in `api_client.endpoints`,
  declare the endpoint — or, if it can't be declared, raise the framework
  gap upstream. This is enforced — an undeclared name fails `--lint`.
- **Pagination stays on the endpoint.** `pagination: offset|cursor` lives
  in your `api_client:` endpoint declaration, not the plan. A single
  `fetch:` already returns the fully-paginated, batch-unwrapped array.
- **Loop variables are loop-scoped.** `as_item: account` is visible only
  inside that `for_each`'s `do:`. Referencing it in `output:` is an
  unbound-name error (caught by `--lint`).
- **Thread epoch-ms through args, not the plan.** Endpoints that
  cursor-paginate on timestamps read `{from_ms}` / `{now_ms}` from the
  kwargs you pass — declare them in the endpoint's `params:` /
  `pagination:` and pass them in the fetch's `args:`.

## Submission checklist (plan variant)

- [ ] `extractor.rb` is deleted; `extract: plan:` is in `workflow.yml`.
- [ ] `freentonic --lint` is clean.
- [ ] `--dump-raw` before/after diffs empty against the Ruby version.
- [ ] Existing normalizer + tests pass unchanged.
- [ ] Every `fetch:` names an endpoint declared in `api_client:`.

See **Revolut** and **Unicaja** in this repo for complete, real plans
over an API, and **N26** for a capture-only one.

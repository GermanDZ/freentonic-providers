# Canonical Data Model Migration — freentonic-providers

## Why this doc exists

freentonic is moving its internal data model to a canonical
`Freentonic::Canonical::CanonicalPayload` shape. Every provider's
`normalizer.rb` in this repo currently emits an ad-hoc shape
(`{source_tag, accounts:[{external_id, legacy_uids, balance_cents,
movements:[{dedup_key, amount_cents}]}]}`) that finanzas-web's
`BankPushController` consumes directly. After the migration, normalizers
must emit `Freentonic::Canonical::CanonicalPayload` instead.

This doc is the per-provider migration plan and lives in the providers
repo so it can be picked up in a session that does not have the
freentonic gem repo open.

## Authoritative references (read first)

All paths below are absolute on the dev machine. Read in this order:

1. **Spec** — `/Users/germandz/personal-code/freentonic/docs/canonical-data-model.md`
   The model itself: envelope, entities, types, IDs, summary, wire format.
2. **Migration plan (gem side)** — `/Users/germandz/personal-code/freentonic/docs/canonical-migration-plan.md`
   The 6-PR sequencing on the freentonic gem. PRs 1–5 have already
   landed (canonical module → formatters → CLI wiring → csv/jsonl
   rewrite → example workflow). This providers-side migration must wait
   for PR 6 (the `http`/`json` exporter default flip and minor version
   bump) before it ships to production receivers.
3. **Formatters** — `/Users/germandz/personal-code/freentonic/docs/formatters.md`
   How wire shapes derive from canonical. You don't write formatters,
   but the contract explains what the receiver will see.
4. **Worked example normalizer** — `/Users/germandz/personal-code/freentonic/examples/normalizer.rb`
   Multi-account, multi-currency, pending+posted, missing fields,
   merchant cleanup. Copy this as the starting structure for each
   provider rewrite.
5. **Receiver-side migration** — `/Users/germandz/personal-code/finanzas-web/docs/freentonic-canonical-migration.md`
   The mirror doc on the receiver side, listing what `BankPushController`
   needs to accept. Coordinate cutover via that doc.

## Current state (pre-migration)

All three normalizers in this repo emit the same envelope shape:

```ruby
{
  "source_tag" => "<provider>_push",
  "accounts" => [
    {
      "external_id"    => "<provider_prefix>:<id>",
      "legacy_uids"    => ["<old prefix>:<id>", ...],
      "iban"           => "ES...",
      "kind"           => "asset" | "liability" | "investment",
      "bank_key"       => "ing" | "ing_cc" | "fintonic_<bank>" | ...,
      "name"           => "...",
      "currency"       => "EUR",
      "balance_cents"  => 123456,
      "balance_source" => "ing_live:product_balance" | nil,
      "metadata"       => { ... },
      "movements"      => [
        {
          "dedup_key"      => "<provider_prefix>:<account>:<mv_uuid>",
          "date"           => "YYYY-MM-DD",
          "amount_cents"   => 4520,
          "currency"       => "EUR",
          "description"    => "...",
          "pending_status" => "pending" | "settled" | nil,
          "raw_payload"    => { "<provider>" => { ... } }
        }
      ]
    }
  ]
}
```

This shape is consumed verbatim by
`/Users/germandz/personal-code/finanzas-web/app/services/bank_data_ingestion/universal_ingestion_service.rb`,
which:

- Does an account-matching cascade keyed on `legacy_uids`/`external_id`,
  then IBAN, then product-number suffix, then name suffix.
- Reads movements as `account.movements[]` (nested under the account).
- Stores money as `amount_cents` integers.
- Uses `dedup_key` for movement upsert (`TransactionJournal.find_by(dedup_key:)`).

## Target state (post-migration)

Every provider's `normalizer.rb` returns
`Freentonic::Canonical::CanonicalPayload`. The wire JSON the receiver
sees becomes:

```json
{
  "schema_version": "0.1",
  "summary": { "counts": {...}, "amounts_by_currency": {...},
               "balances_by_currency": {...}, "date_range": {...},
               "generated_at": "..." },
  "meta": { "scraper_version": "...", "freentonic_run_id": "..." },
  "accounts": [
    {
      "id":           "acc_<16hex>",
      "source_id":    "<bank_uuid>",
      "institution":  "ing" | "fintonic" | "revolut",
      "name":         "...",
      "type":         "checking" | "savings" | "credit_card" | "investment",
      "currency":     "EUR",
      "iban":         "ES...",
      "balance":      { "current": "1234.56", "available": "1200.00",
                        "timestamp": "2026-04-23T10:00:00Z" },
      "metadata":     { ... }
    }
  ],
  "transactions": [
    {
      "id":               "txn_<16hex>",
      "source_id":        "<bank movement uuid>",
      "account_id":       "acc_<16hex>",   // FK into accounts[]
      "date":             "YYYY-MM-DD",
      "value_date":       "YYYY-MM-DD" | null,
      "amount":           "-45.20",        // BigDecimal as JSON STRING
      "currency":         "EUR",
      "description":      "...",
      "raw_description":  "...",
      "status":           "posted" | "pending",
      "merchant":         { "name": "...", "normalized": true } | null,
      "category":         null,
      "metadata":         { "<provider>": { ... } }   // raw_payload moves here
    }
  ],
  "liabilities": [],
  "investments": []
}
```

Key shape changes vs. today:

- `transactions` is a top-level slot, not nested under accounts. Each
  transaction carries `account_id` referencing an account in the same
  envelope.
- IDs (`id`) are SHA-256-derived deterministic values prefixed with
  `txn_` / `acc_` / `liab_` / `inv_`. The provider does NOT roll its
  own — call `Freentonic::Canonical.transaction_id(...)` etc.
- Money is `BigDecimal` internally and a JSON string on the wire. No
  more `*_cents`.
- `source_id` carries the raw bank-side ref as a first-class field —
  unique within a single source only.
- `metadata` per entity is still free-form; tuck the old `raw_payload`
  contents there.
- `kind` and `bank_key` from the old shape don't map 1:1 into canonical
  — see the per-provider table below.

### Legacy-compatibility metadata (transition window only)

To make the receiver-side cutover self-healing, every entity carries
its old-shape stable identifiers inside `metadata` during the transition
window. The receiver looks these up first when it cannot find a row by
canonical id, then backfills the canonical id onto the matched row, so
each historical record migrates itself the first time a canonical push
touches it. No receiver-side template guessing, no duplicate window, no
backfill rake task.

Emitted on every `Account.metadata`:

```json
{
  "legacy_external_id": "ing_live:abc-123",
  "legacy_uids":        ["ing_live:abc-123"],
  "legacy_bank_key":    "ing"
}
```

Emitted on every `Transaction.metadata`:

```json
{
  "legacy_dedup_key": "ing_live:abc-123:mv-uuid"
}
```

These values match exactly what the same provider's pre-migration
normalizer would have emitted for the same source record. Each provider
keeps a small private helper that produces them so the format does not
drift from the legacy normalizer it replaced. After the receiver
confirms cutover (see "Phase 4 — drop legacy compatibility" below),
each provider drops these fields in a follow-up PR.

## Per-provider field mapping

### Account

| Today (per-provider)           | Canonical (`Canonical::Account`)                                                                                |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| `external_id`                  | `id` — but recomputed via `Canonical.account_id(institution:, iban:, source_id:, name:)`. Stop hand-rolling. |
| `legacy_uids`                  | **dropped from the wire.** finanzas-web matches on `id` (deterministic) and `source_id` after migration. The receiver's matching cascade handles back-compat for one-time-only legacy lookups during cutover — see receiver doc. |
| `iban`                         | `iban`                                                                                                         |
| `kind` ("asset" / "liability" / "investment") | Picks the slot:<br>• asset → `accounts[]` with `type: "checking"` / `"savings"` / etc.<br>• liability → `liabilities[]`<br>• investment → `investments[]` (and an `accounts[]` entry is still required if balances flow through it) |
| `bank_key`                     | `institution` — but the value is just the provider slug now (`"ing"` / `"fintonic"` / `"revolut"`). No `_cc` variant. The credit-card/checking distinction lives in `Account.type` (`"credit_card"`) and Liability presence. |
| `name`                         | `name`                                                                                                         |
| `currency`                     | `currency`                                                                                                     |
| `balance_cents`                | `balance.current` (string decimal). Convert via `(cents / 100.0).to_s`. Drop `*_cents` naming. |
| `balance_source`               | `balance.metadata` or top-level `metadata["balance_source"]`. NOT a dedicated canonical field. |
| `metadata`                     | `metadata` (free-form, preserve as-is) PLUS the legacy-compat keys: `metadata["legacy_external_id"]` = old `external_id`, `metadata["legacy_uids"]` = old `legacy_uids`, `metadata["legacy_bank_key"]` = old `bank_key`. See "Legacy-compatibility metadata" above — these stay until receiver cutover is confirmed. |
| —                              | `source_id` — set to the raw bank uuid/ref (e.g. ING's `product["uuid"]`, Fintonic's `"#{bank_id}:#{product_id}"`). Distinct from `id`. |

### Movement → Transaction

| Today                          | Canonical (`Canonical::Transaction`)                                                                            |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| `dedup_key`                    | `id` — recomputed via `Canonical.transaction_id(account_id:, date:, amount:, raw_description:)`. The dedup property is preserved (deterministic), so finanzas-web's `find_by(dedup_key:)` becomes `find_by(canonical_id:)`. |
| `date`                         | `date`                                                                                                         |
| —                              | `value_date` — populate when the bank exposes it (ING `clearingDate`, etc.).                                  |
| `amount_cents`                 | `amount` (string decimal). `(cents / 100.0).to_s`.                                                            |
| `currency`                     | `currency`                                                                                                     |
| `description`                  | `description` (cleaned) and `raw_description` (untouched) — split into the two canonical fields.              |
| `pending_status` ("pending" / "settled" / nil) | `status` ("pending" / "posted" / nil). Note the rename `settled → posted`. |
| `raw_payload`                  | `metadata` (move the per-provider sub-hash here verbatim) PLUS `metadata["legacy_dedup_key"]` = the old `dedup_key` value. See "Legacy-compatibility metadata" above. |
| —                              | `source_id` — the raw bank ref (e.g. ING `mv["uuid"]`).                                                       |
| —                              | `account_id` — must equal the canonical `id` of the corresponding `Account`.                                  |
| —                              | `merchant` — populate when the source has merchant info (Fintonic does; ING/Revolut may not).                 |

### Provider-specific notes

#### ING (`/Users/germandz/personal-code/freentonic-providers/ing/normalizer.rb`)

- `Extractor::KIND_BY_PRODUCT_TYPE` decides asset vs liability — keep
  using it to route products to `accounts[]` vs `liabilities[]`.
- `kind == "liability"` items previously emitted `bank_key: "ing_cc"`
  and a `legacy_uid` like `ing-cc-<uuid>`. In canonical: institution
  `"ing"`, `Account.type: "credit_card"`, AND a `Liability` entry that
  references the account.
- `pending_status: "settled"` → `status: "posted"`.
- `raw_payload["ing"]` → `metadata["ing"]`.

#### Fintonic (`/Users/germandz/personal-code/freentonic-providers/fintonic/normalizer.rb`)

- `external_id: "fintonic:#{bank_id}:#{product_id}"` →
  `source_id: "#{bank_id}:#{product_id}"` and `id` recomputed by helper.
- Fintonic gives no IBAN — pass `source_id` to `Canonical.account_id` as
  the stable ref. The helper accepts it.
- `category_id` / `category_path` / `merchant_name` from `raw_payload`
  should populate `Transaction.category` and `Transaction.merchant.name`
  (with `normalized: true` if Fintonic's name lookup was deterministic).

#### Revolut (`/Users/germandz/personal-code/freentonic-providers/revolut/normalizer.rb`)

- Pockets / sub-accounts: each pocket becomes its own `Account` with a
  distinct `source_id`. Don't collapse them.
- Multi-currency: every transaction must carry the pocket's currency,
  not the user's home currency.

## Implementation plan

### Step 0 — Wait for freentonic PR 6

The `http` exporter default already produces canonical JSON for
`CanonicalPayload`-returning normalizers (PR 3, landed). But the
release that flips the example workflow and bumps the gem version is
PR 6, not yet shipped. Do not merge any provider migration to `main`
until freentonic's PR 6 has tagged a release that downstream pin to.

Track via `/Users/germandz/personal-code/freentonic/docs/canonical-migration-plan.md`'s
"Step 6" section.

### Step 1 — Bump freentonic gem dependency

In this repo's `Gemfile.lock`, update the freentonic gem to the version
shipped by PR 6. Smoke-run any existing test suite to confirm the gem
still loads and existing normalizers still pass through (the legacy
Hash shape they emit today still works through `http`/`json` exporters
because `Canonical#call(hash)` is the identity on Hashes).

### Step 2 — Migrate one provider end-to-end (recommend Ing first)

Ing has the richest test fixtures and the most complete shape (all of
asset/liability, pending/posted, IBAN, raw_payload). It is the best
proving ground.

Files touched:
- `/Users/germandz/personal-code/freentonic-providers/ing/normalizer.rb` — rewrite to return `CanonicalPayload`.
- `/Users/germandz/personal-code/freentonic-providers/ing/test/normalizer_test.rb` — rewrite assertions against canonical entities.

Do **not** change `extractor.rb` unless the rewrite reveals a missing
field upstream — minimize churn.

Sanity loop:
```
cd /Users/germandz/personal-code/freentonic-providers
bundle exec rake test  # or direct minitest
```

End-to-end smoke against the receiver via `bin/freentonic invoke ...
--export http --export-url <staging finanzas-web push endpoint>` only
after the receiver has accepted canonical (see receiver doc). Until
then, dump canonical JSON to disk and eyeball it:
```
bin/freentonic invoke /Users/germandz/personal-code/freentonic-providers/ing/workflow.yml \
  --export json --export-path /tmp/ing.canonical.json
```
The output should start with `{"schema_version":"0.1",...`.

### Step 3 — Migrate Fintonic, then Revolut

Same pattern, one PR each. Fintonic before Revolut because it has
better test coverage of merchant/category fields, which Revolut barely
exercises.

### Step 4 — Drop the dead helpers

Once all three providers emit canonical:
- Remove any `*_cents`-flavored helpers that don't survive the
  rewrite.
- Update each provider's README / inline docs to point at the
  spec (absolute path above).

Do NOT drop the `metadata["legacy_*"]` fields yet — they are still
load-bearing for receiver-side self-healing matching. See Step 6.

### Step 5 — Coordinate receiver cutover

Ping the finanzas-web doc owner. Cutover is a coordinated push:
1. Receiver deploys back-compat code that accepts both shapes (see
   receiver doc, "phased adoption"). This includes the metadata-driven
   legacy lookup that depends on the providers emitting
   `metadata["legacy_*"]`.
2. Each provider's PR can then merge independently. Each provider PR
   already includes the legacy-compat metadata, so the first push from
   any migrated provider self-heals existing rows on the receiver.
3. Once all three providers are on canonical and the receiver confirms
   the legacy-lookup branch hasn't fired in a while (see Step 6), drop
   the legacy fields.

### Step 6 — Phase out legacy-compatibility metadata

After all providers are on canonical and the receiver-side telemetry
shows the legacy-lookup branch hasn't matched a row in N consecutive
syncs (suggested: 4 weeks of normal runs, or whatever the receiver
owner is comfortable with), drop the legacy fields:

- `metadata["legacy_external_id"]`
- `metadata["legacy_uids"]`
- `metadata["legacy_bank_key"]`
- `metadata["legacy_dedup_key"]`

One PR per provider. Trivial change — just delete the helper that
emits them. Coordinate with the receiver to drop the legacy-lookup
branch in the same release cycle.

If the receiver later wants to surface canonical-only fields
(`merchant`, `category`, `value_date`, `summary`), this is also when
the canonical adapter on the receiver side either (a) gets dropped
entirely in favor of direct canonical consumption, or (b) is
simplified to no longer carry the legacy-lookup logic.

## Coordination & sequencing summary

```
freentonic gem      providers                     finanzas-web (receiver)
───────────────     ────────────                  ──────────────────────
PRs 1–5 ✅
PR 6 (release) ─────► bump dep + smoke ─────► already ships back-compat code
                          │                         (accepts canonical AND
                          ▼                          legacy shapes during
                       Ing PR ─────────────────────► transition window)
                          │
                       Fintonic PR ───────────────►
                          │
                       Revolut PR ────────────────►
                          │
                          ▼
                     legacy_uids cleanup ────────► receiver removes legacy
                                                    branch
```

Provider PRs cannot land before the receiver ships back-compat (else
production pushes break). They cannot start before freentonic PR 6
ships (else the gem dep doesn't exist).

## Field-by-field checklist (per provider PR)

Use this when reviewing each rewrite:

- [ ] `Freentonic::Canonical::CanonicalPayload.new` with explicit
      `accounts:`, `transactions:`, optionally `liabilities:` /
      `investments:`, and `meta: { "scraper_version" => "..." }`.
- [ ] Every `Account.id` produced via `Canonical.account_id(...)`.
- [ ] Every `Transaction.id` produced via `Canonical.transaction_id(...)`.
      No hand-rolled hashes.
- [ ] `source_id` populated from the raw bank UUID/ref (different from
      `id`).
- [ ] Money fields are passed as numerics or strings — never
      pre-multiplied to cents. The factory coerces to BigDecimal.
- [ ] `raw_payload` contents moved to `Transaction.metadata[<provider>]`.
- [ ] `pending_status: "settled"` rewritten to `status: "posted"`.
- [ ] `kind: "liability"` items routed to `liabilities:` slot AND the
      corresponding `Account.type` set to `"credit_card"` if applicable.
- [ ] Every `Account.metadata` carries `legacy_external_id`,
      `legacy_uids`, and `legacy_bank_key` matching exactly what the
      pre-migration normalizer would have emitted for the same
      `product`. Cross-checked with the deleted/replaced lines from the
      old normalizer.
- [ ] Every `Transaction.metadata` carries `legacy_dedup_key` matching
      exactly what the pre-migration normalizer would have emitted for
      the same `mv`. Cross-checked the same way.
- [ ] Test coverage updated: assert canonical shape, assert
      deterministic IDs are stable across two calls with the same raw,
      assert money string format (`"-45.20"`), assert legacy-compat
      keys present and bit-exact against a fixture captured from the
      old normalizer.
- [ ] Smoke output (`bin/freentonic invoke ... --export json`) starts
      with `{"schema_version":"0.1",...` and contains
      `"legacy_dedup_key"` strings inside transaction metadata.

## Open questions to resolve before starting

1. **`balance.timestamp`.** Today the providers don't emit a balance
   timestamp. Decide per provider whether one of the fetch responses
   carries one (ING's product detail does, Fintonic likely not). If
   not, leave `balance.timestamp` `nil`.

2. **Ing card vs. account.** Ing credit cards today produce both an
   `account` row (`bank_key: "ing_cc"`, `kind: "liability"`) AND
   movements. In canonical, the cleanest mapping is one `Account` (with
   `type: "credit_card"`) AND one `Liability` referencing it. Confirm
   the receiver's preferred shape before implementing.

3. **Telemetry signal for Step 6.** The receiver needs to expose
   "legacy-lookup branch fired N times in the last sync" so we know when
   it's safe to drop the legacy-compat metadata. Confirm with the
   receiver owner what counter / log line / metric they will surface.

The previously-open "bank key derivation" and "legacy_uids backfill"
questions are now answered by the legacy-compat metadata approach: the
provider emits the authoritative legacy strings inline, so the receiver
neither has to reconstruct `bank_key` from canonical fields nor maintain
a per-institution legacy-uid template.

# Creating a new provider

This doc walks you through adding a new provider (bank, broker, utility,
…) to `freentonic-providers`. If you've never used freentonic before,
read the [framework README](https://github.com/GermanDZ/freentonic)
first — it covers the pipeline stages, YAML reference, and pluggable
backends this doc assumes you've seen.

## TL;DR

A provider is a directory with no Ruby in it outside its tests:

```
my_bank/
├── workflow.yml      # login + capture phases, api_client, and two plans:
│                     #   extract: plan:   captured session → raw payload
│                     #   normalize: plan: raw payload → canonical payload
├── config.yml        # constants the normalize plan reads as {config.*}
└── test/
    ├── my_bank_extract_credentials_test.rb
    ├── my_bank_extract_plan_test.rb
    └── my_bank_normalizer_test.rb
```

Both plans are interpreted by the framework
([`extract-plan.md`](https://github.com/GermanDZ/freentonic/blob/main/docs/extract-plan.md),
[`normalize-plan.md`](https://github.com/GermanDZ/freentonic/blob/main/docs/normalize-plan.md)). That's the only wiring
you need — there is no central registry, no gemspec change, no
boilerplate.

> **Why no Ruby?** freentonic ≥ 0.18.0 refuses provider Ruby
> (`extract: ruby:`, `normalize: ruby:`, `api_client.ext`) at run start
> unless it's started with `FREENTONIC_ALLOW_PROVIDER_RUBY=1`, and
> production servers run without it — so no provider-authored code runs
> during a sync. If a plan can't express something, that's a framework
> gap to raise upstream (see `AGENTS.md`), not a reason for an
> `extractor.rb`.

## 1. Scaffold the directory

```sh
rake new[my_bank]   # or by hand:
mkdir -p my_bank/test
touch my_bank/{workflow.yml,config.yml}
touch my_bank/test/my_bank_{extract_credentials,extract_plan,normalizer}_test.rb
```

Use snake_case for the directory name — it becomes the `config.key` in
the YAML and the service/account name in secret backends.

## 2. Write the workflow YAML

Start from the skeleton below. Every key is documented in the framework
[`README`](https://github.com/GermanDZ/freentonic#workflow-yaml-reference);
the quick-reference version:

```yaml
version: 1

config:
  key: my_bank
  default_lookback_days: 30

# Named secret entries. The `prompt:` is shown on first run; the backend
# (macOS Keychain, etc.) caches it afterwards. Reference a secret inside
# any step value as "secret(NAME)".
secrets:
  USER_DNI:
    prompt: "My Bank user / DNI"
  USER_PASSWORD:
    prompt: "My Bank password"

# Login + credential-capture pipeline. Each phase name must appear in
# `phases:` below. The framework runs them in order inside the same
# headed Chrome session.
pipeline:
  - connect
  - login
  - capture_credentials

phases:
  connect:
    - action: navigate
      url: "https://my-bank.example/login"
    - action: wait_url
      includes: "my-bank.example"
      timeout: 15
  login:
    - action: wait_for_selector
      selector: "input#user"
    - action: fill
      selector: "input#user"
      value: "secret(USER_DNI)"
    - action: fill
      selector: "input#pass"
      value: "secret(USER_PASSWORD)"
    - action: click
      selector: "button[type='submit']"
    - action: wait_url
      includes: "/dashboard"
      timeout: 60
  capture_credentials:
    - action: wait_network_idle
      seconds: 3
    - action: capture_cookie_header
      host: "my-bank.example"
      path: "/api/"
      as: cookie
    - action: capture_header
      name: "X-CSRF-Token"
      as: csrf_token
      retries: 3
      interval_seconds: 1

# Translate the captured workflow_context (cookies, headers, etc.) into
# the credentials hash that the Extract stage receives. `require:` fails
# loudly if a key is missing, `validate:` adds shape checks, and `map:`
# produces the final hash (keys become symbols).
credentials:
  require:
    - cookie
    - csrf_token
  validate:
    - key: cookie
      not_empty: true
  map:
    - { from: cookie,     as: cookie }
    - { from: csrf_token, as: csrf_token }

# Dynamically-built HTTP client. Each entry in `endpoints:` becomes a
# method on the instance that the Extract stage receives, so calling
# `client.fetch_accounts` just works.
api_client:
  base_url: "https://api.my-bank.example"
  api_root: "/v1"
  credentials: [cookie, csrf_token]
  auth_headers:
    Cookie: "{cookie}"
    X-CSRF: "{csrf_token}"
  batch_keys: [items, results]
  date_format: "%Y-%m-%d"
  endpoints:
    - name: fetch_accounts
      method: GET
      path: "/accounts"
    - name: fetch_movements
      method: GET
      path: "/accounts/{account_id}/movements"
      params:
        from:  "{from_date|date}"
        limit: 100
        offset: "{offset}"
      pagination: offset
      limit: 100

# extract: plan: and normalize: plan: — see sections 3 and 4.
```

Lint after every change — schema, plan verbs, `{token}` references and
endpoint names are all checked without a browser or network:

```sh
freentonic --lint --workflow my_bank/workflow.yml
```

### YAML authoring tips

- **Start with the browser DevTools open** while you manually log in. The
  Network panel shows the exact selectors, URL shapes, and auth headers
  you need.
- **Pipeline actions are documented in**
  the framework's `docs/workflow-actions.md` and the individual
  `docs/workflow-action-*.md` files. Key actions include `pause`,
  `record_requests`, `dump_requests`, `enter_digits`, and
  `capture_response_json` — read the reference before assuming an action
  doesn't exist.
- `secret(NAME)` works inside strings and inside arrays of strings
  (e.g. `digits:` inputs), and is resolved recursively through hashes.
  You can index into a secret: `secret(PIN[0])` returns the first character.
- Use `--isolated` during initial authoring so your tweaks to the
  workflow don't accumulate Chrome state that's hard to reason about.

### YAML gotchas

- **`{offset}` is a reserved interpolation token.** The framework
  intercepts `{offset}` in endpoint params to inject the automatic
  pagination offset. If you use it as a kwarg name for manual
  pagination, it will silently resolve to `nil` and your requests will
  always fetch page 0. Use `{page_offset}` instead.
- **`batch_keys` unwraps responses.** If you set
  `batch_keys: [resultList]`, parameterized endpoint methods return the
  extracted array — NOT the full response hash. If your plan needs
  metadata like the response's `count` alongside the batch, omit
  `batch_keys` and read the full response.
- **Use `_if_present` for multi-state login flows.** Banks remember
  sessions in various ways — email remembered, PIN skipped, straight to
  2FA. Use `wait_for_first_of` to detect which state, then
  `fill_if_present` / `click_if_present` so unused steps are no-ops.
- **Scope shared button IDs with `:has()`.** If a button ID like
  `#loginButton` exists on multiple pages, use
  `body:has(#emailInput) #loginButton` to only click it when the email
  form is present. Chrome supports `:has()` since v105.

## 3. Write the extract plan

The extract plan owns "I have credentials, give me a raw payload from the
provider API." It calls the endpoints declared in `api_client:` (and only
those), loops over products, and assembles the raw payload:

```yaml
# Captured session → raw payload:
#   { accounts: [<account>], movements: { <account id>: [<movement>] } }
extract:
  plan:
    steps:
      # The product list is essential: no on_error/safe, so a dead
      # session fails the run as "re-run connect", not as 0 accounts.
      - fetch: fetch_accounts
        as: accounts
      - for_each:
          source: accounts
        as_item: account
        as: movements
        collect: map
        key: "{account.id}"
        do:
          # One failing account mustn't sink the run: safe: logs it to
          # stderr and binds default: instead.
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

The plan's output is what `--dump-raw` persists and what the normalize
plan reads as `raw`. Keep it close to the API's own rows — reshape only as
much as normalization needs.

**Error handling:** isolate a single product's failure (`safe: true`, or
`on_error: { warn: … }`) so a failing card doesn't sink the run, but fail
loudly when the run can't do without something — `on_error: { abort: … }`
on the product list, `abort:` when an essential value is absent. An
expired session must surface as "re-run connect", never as an
empty-but-successful sync.

**Pagination** belongs on the endpoint (`pagination:` — offset, as above,
or `kind: cursor` as in `revolut/workflow.yml`), so the plan sees one
flattened list. Bound it by the lookback: pass `{from_date}` to the
endpoint, or stop a cursor with `continue_when` on `{from_ms}`.

**No usable API?** When the app's requests can't be replayed (N26
encrypts them in the page), there's no `api_client:`: capture the app's
own responses with `capture_response_json` and hand them to the plan in a
top-level `captured:` block instead of `credentials:`. See `n26/` and
freentonic's [capturing data from a web app's own responses](https://github.com/GermanDZ/freentonic/blob/main/docs/workflow-action-capture-response-json.md#capturing-data-from-a-web-apps-own-responses).

More patterns (first-present fallbacks, joins with `index_by:` /
`lookup:`, `when:` gates, `dedup_by:`) are in
[writing-extract-plans.md](writing-extract-plans.md) and freentonic's
[`extract-plan.md`](https://github.com/GermanDZ/freentonic/blob/main/docs/extract-plan.md).

## 4. Write the normalize plan

The normalize plan turns the raw payload into freentonic's **canonical
payload** — accounts and transactions with deterministic ids, defined in
[`canonical-data-model.md`](https://github.com/GermanDZ/freentonic/blob/main/docs/canonical-data-model.md). The
`build_account` / `build_transaction` functions construct and validate
the entities, so the shape can't drift:

```yaml
# Raw payload → canonical accounts + transactions.
normalize:
  plan:
    steps:
      - select: { from: raw, path: accounts, default: [] }
        as: raw_accounts
      - select: { from: raw, path: movements, default: {} }
        as: movements_by_account
      - for_each: { source: raw_accounts }
        as_item: acct
        as: results
        do:
          - select: { from: acct, path: id }
            as: acct_id
          - skip_when: { acct_id: { absent: true } }
          - let: currency
            coalesce: ["{acct.currency}", "EUR"]
          - apply: cents
            args: { amount: "{acct.balance}" }
            as: balance_cents
          - apply: cents_to_amount
            args: { cents: "{balance_cents}" }
            as: balance_amount
          - apply: remove_whitespace
            args: { value: "{acct.iban}" }
            as: iban
          - select: { from: acct, path: product_type }
            as: product_type
          - let: account_type
            value: credit_card
            when: { product_type: { eq: credit_card } }
          - let: account_type
            coalesce: ["{account_type}", "checking"]
          - apply: build_account
            args:
              institution: "{config.institution}"
              source_id: "{acct_id}"
              currency: "{currency}"
              name: "{acct.name}"
              type: "{account_type}"
              iban: "{iban}"
              balance: { current: "{balance_amount}", timestamp: null }
            as: account

          - lookup: { from: movements_by_account, key: "{acct_id}", default: [] }
            as: rows
          - for_each: { source: rows }
            as_item: mv
            as: txns
            do:
              - apply: cents
                args: { amount: "{mv.amount}" }
                as: amount_cents
              - skip_when: { amount_cents: { absent: true } }
              - apply: cents_to_amount
                args: { cents: "{amount_cents}" }
                as: amount
              - apply: parse_date
                args:
                  value: "{mv.date}"
                  input_timezone: "{config.input_timezone}"
                  output_timezone: "{config.output_timezone}"
                as: date
              - skip_when: { date: { absent: true } }
              - apply: strip
                args: { value: "{mv.description}" }
                as: description
              - apply: build_transaction
                args:
                  account_id: "{account.id}"
                  source_id: "{mv.id}"
                  amount: "{amount}"
                  currency: "{currency}"
                  date: "{date}"
                  description: "{description}"
                  raw_description: "{description}"
                  status: posted
                as: txn
              - yield: "{txn}"
          - yield: { account: "{account}", txns: "{txns}" }

      - apply: pluck
        args: { list: "{results}", key: account }
        as: accounts
      - apply: pluck
        args: { list: "{results}", key: txns }
        as: txn_groups
      - apply: flatten
        args: { list: "{txn_groups}" }
        as: transactions
    output:
      accounts: "{accounts}"
      transactions: "{transactions}"
```

Its constants live in `config.yml`, read as `{config.*}`:

```yaml
# my_bank/config.yml
# Constants the normalize plan reads as {config.*}.
institution: my_bank
scraper_version: my_bank/0.1
# The calendar day a movement is booked on, independent of where
# freentonic runs.
input_timezone: Europe/Madrid
output_timezone: Europe/Madrid
```

- **Amounts:** `apply: cents` accepts major units, minor units
  (`already_minor: true`), a `{amount, currency}` Hash, or a comma-decimal
  String, and returns integer cents; `cents_to_amount` turns that into
  the canonical decimal.
- **Dates:** give `parse_date` (or `parse_timestamp_ms`) explicit
  timezones from `config.yml`, so the booking day doesn't depend on where
  freentonic runs.
- **Gates take bound names:** `when:` / `skip_when:` compare a name bound
  by an earlier step against a literal — `select:` a field first, as with
  `product_type` above.
- **Statuses and metadata:** `map_status` with a `config.yml` map, and
  `extract_fields` with a `config.yml` allowlist of raw fields to keep.

Every registered function is listed by `freentonic --schema-json`; the
full grammar is in freentonic's
[`normalize-plan.md`](https://github.com/GermanDZ/freentonic/blob/main/docs/normalize-plan.md).

## 5. Iterate with `--dump-raw` / `--from-raw`

The killer feature of freentonic is that you only have to log into the
bank **once**. Capture a raw payload, then iterate on your normalizer
against the dumped JSON:

```sh
# One-time: go through the login, capture, and extract stages. The raw
# payload lands on disk.
freentonic --workflow my_bank/workflow.yml \
  --through extract --dump-raw /tmp/my_bank_raw.json

# Every iteration after that: skip Chrome entirely, replay from disk.
freentonic --workflow my_bank/workflow.yml \
  --from-raw /tmp/my_bank_raw.json \
  --export json --export-path /tmp/my_bank_normalized.json

# Inspect the result and tweak the normalize plan. Repeat the second command.
```

Use `--dump-normalized` + `--from-normalized` the same way if you want
to iterate on exporter config without re-running the normalizer.

## 6. Write tests

Three small test files, none of which touch Chrome or the bank. The
first validates the credentials mapping in `workflow.yml`, the second
runs the extract plan against a fake api_client, the third runs the
normalize plan on a small hand-crafted raw payload.

```ruby
# my_bank/test/my_bank_extract_credentials_test.rb
require "minitest/autorun"
require "stringio"
require "freentonic"

class MyBankExtractCredentialsTest < Minitest::Test
  WORKFLOW_PATH = File.expand_path("../workflow.yml", __dir__)

  def source
    Freentonic::Source.new(workflow_path: WORKFLOW_PATH)
  end

  def test_maps_captured_context_to_credentials
    credentials = source.extract_credentials(
      nil,
      workflow_context: { "cookie" => "sid=abc", "csrf_token" => "tok-123" },
      stdout: StringIO.new, stderr: StringIO.new
    )

    assert_equal({ cookie: "sid=abc", csrf_token: "tok-123" }, credentials)
  end

  def test_raises_when_required_key_missing
    assert_raises(Freentonic::UserError) do
      source.extract_credentials(nil, workflow_context: {}, stdout: StringIO.new, stderr: StringIO.new)
    end
  end
end
```

```ruby
# my_bank/test/my_bank_extract_plan_test.rb
require "minitest/autorun"
require "stringio"
require "date"
require "freentonic"

class MyBankExtractPlanTest < Minitest::Test
  WORKFLOW = File.expand_path("../workflow.yml", __dir__)

  # Stands in for the generated api_client: one method per endpoint name.
  class FakeClient
    def fetch_accounts = [{ "id" => "acc-1", "name" => "Checking" }, { "id" => "acc-2", "name" => "Card" }]

    def fetch_movements(account_id:, from_date:)
      raise "HTTP 500" if account_id == "acc-2"

      [{ "id" => "mv-1", "date" => "2024-03-15", "amount" => -12.34 }]
    end
  end

  def extract
    schema = Freentonic::WorkflowSchema.load(WORKFLOW)
    Freentonic::ExtractPlan::PlanExtractor.new(
      schema.raw.dig("extract", "plan"), endpoint_names: schema.api_client_endpoint_names
    ).call(client: FakeClient.new, credentials: {}, from_date: Date.new(2024, 1, 1),
           stdout: StringIO.new, stderr: StringIO.new)
  end

  def test_fetches_movements_per_account
    assert_equal 1, extract["movements"].fetch("acc-1").size
  end

  def test_a_failing_account_does_not_sink_the_run
    assert_equal [], extract["movements"].fetch("acc-2")
  end
end
```

```ruby
# my_bank/test/my_bank_normalizer_test.rb
require "minitest/autorun"
require "bigdecimal"
require "stringio"
require "date"
require "freentonic"

class MyBankNormalizerTest < Minitest::Test
  WORKFLOW = File.expand_path("../workflow.yml", __dir__)

  def normalize(raw)
    Freentonic::Normalizers::Builder.for_workflow(WORKFLOW, stdout: StringIO.new, stderr: StringIO.new).call(raw)
  end

  def test_normalizes_a_basic_account_with_movements
    payload = normalize(
      "accounts" => [{ "id" => "acc-1", "name" => "Checking", "iban" => "ES00 1234 5678 9012 3456 7890",
                       "currency" => "EUR", "balance" => 1234.56, "product_type" => "current" }],
      "movements" => { "acc-1" => [{ "id" => "mv-1", "date" => "2024-03-15", "amount" => -12.34,
                                     "description" => " Coffee " }] }
    )

    account = payload.accounts.first
    assert_equal "checking", account.type
    assert_equal "ES0012345678901234567890", account.iban
    assert_equal BigDecimal("1234.56"), account.balance.current

    txn = payload.transactions.first
    assert_equal account.id, txn.account_id
    assert_equal BigDecimal("-12.34"), txn.amount
    assert_equal Date.new(2024, 3, 15), txn.date
    assert_equal "Coffee", txn.description
  end
end
```

A capture-only provider (no `api_client:`, data via `captured:`) has no
client to fake and no credentials to map: run the real Extract stage over
a synthetic connect context instead, which tests the `captured:`
declaration too — see `n26/test/n26_harness.rb`. Keep date assertions
independent of the machine's time zone.

Run everything with:

```sh
bundle exec rake test:my_bank
```

If you're iterating fast, run one test file directly without the
Rakefile overhead:

```sh
ruby -Imy_bank -I../freentonic/lib my_bank/test/my_bank_normalizer_test.rb
```

## 7. Security checklist

Before you commit your provider, walk through this list:

- [ ] **No secrets in the YAML or in fixtures.** Passwords, PINs, CSRF
      tokens, real cookies — none of these belong in version control.
      Secrets must resolve via `secret(NAME)` at runtime.
- [ ] **No bank HTML/JSON captures with personal data in `test/`.**
      Hand-craft the minimal fixture a test needs. If you must use real
      shape, scrub amounts, names, and IDs.
- [ ] **The extract plan isolates per-product failures** (`safe:` /
      `on_error: warn`) but never masks an expired session, so the user is
      prompted to re-login.
- [ ] **You've read every line of `workflow.yml` and `config.yml` you
      wrote**, and you understand what each step does. Future
      contributors will copy from you.
- [ ] **A `captured:` entry names data, never a cookie or token** — plan
      output is persisted (`--dump-raw`, run artifacts).
- [ ] **Tests pass under `bundle exec rake test:<your_provider>`.**

## 8. Submission checklist

- [ ] Directory is snake_case and matches `config.key`.
- [ ] `workflow.yml` is version: 1 and `freentonic --lint` is clean.
- [ ] Extract and normalize are both plans: no `ruby:` stage, no
      `api_client.ext`, and no Ruby in the provider dir outside `test/`.
- [ ] CI is green against the pinned freentonic release — if you need a
      newer one, see "After you hand the drafts over" in `AGENTS.md`.
- [ ] README.md's provider table in the repo root lists your new
      provider with status (`v1`, `experimental`, `deprecated`, …) and
      a one-sentence note.
- [ ] Pre-submission security walkthrough above.
- [ ] `bundle exec rake test` green locally.

## Reference providers

If you're unsure how to model something, read the existing providers —
they cover different styles of API and login flow:

- [`ing/`](../ing) — the v2 `/search` API. Shows `derived_credentials`
  regex extraction from a cookie header, a `wait_for_shadow_selector` +
  `enter_pin_pad` login, and a declarative `elevate:` phase (PSD2 push
  approval + Bearer rebind) gated on the lookback.
- [`unicaja/`](../unicaja) — the Univia REST API. Shows a POST-form API
  client, multiple product types (cuentas + tarjetas + préstamos) in one
  extract plan, a `when:` gate for the extended-history fetch with
  endpoint-level cursor pagination, and the `tokencsrf` header capture
  flow.
- [`revolut/`](../revolut) — PKCE OAuth login, push-notification 2FA,
  cookie+header auth. Multi-product fetch (wallet, cards, vaults) with
  cursor-paginated transactions. Shows `capture_cookie_header` for
  httpOnly cookies.
- [`fintonic/`](../fintonic) — aggregator with Bearer token auth. Shows
  3-state login handling (`wait_for_first_of` + `_if_present`), SMS 2FA
  via `prompt_stdin_and_fill`, per-digit PIN entry via `secret(PIN[N])`
  indexing, `:has()` scoped clicks, manual offset pagination with
  `{page_offset}` (avoiding the reserved `{offset}`), and the
  `record_requests` + `dump_requests` investigation pattern. Its
  normalizer is still a Ruby `normalizer.rb` pending a port, so it
  needs `FREENTONIC_ALLOW_PROVIDER_RUBY=1` — don't copy that part.
- [`n26/`](../n26) — **no usable API**: the web app encrypts its
  requests, so the workflow drives the app with in-app clicks after a
  hydration settle, captures its GraphQL responses, pages "Load more"
  history with `click_while_present`, and hands everything to the plan
  through `captured:`. Its tests run the real Extract stage
  (`n26/test/n26_harness.rb`).

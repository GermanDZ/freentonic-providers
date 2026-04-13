# Creating a new provider

This doc walks you through adding a new provider (bank, broker, utility,
…) to `freentonic-providers`. If you've never used freentonic before,
read the [framework README](https://github.com/GermanDZ/freentonic)
first — it covers the pipeline stages, YAML reference, and pluggable
backends this doc assumes you've seen.

## TL;DR

A provider is a directory containing four things:

```
my_bank/
├── workflow.yml      # declarative login + API client config
├── extractor.rb      # hits the API with captured credentials → raw payload
├── normalizer.rb     # raw payload → universal account/movement shape
└── test/
    ├── my_bank_extract_credentials_test.rb
    └── my_bank_normalizer_test.rb
```

The framework's `Stages::Extract` and `Stages::Normalize` load
`extractor.rb` and `normalizer.rb` from relative paths declared in
`workflow.yml`. That's the only wiring you need — there is no central
registry, no gemspec change, no boilerplate.

## 1. Scaffold the directory

```sh
mkdir -p my_bank/test
touch my_bank/{workflow.yml,extractor.rb,normalizer.rb}
touch my_bank/test/my_bank_normalizer_test.rb
touch my_bank/test/my_bank_extract_credentials_test.rb
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

# Point at the sibling Ruby files. Paths are relative to THIS YAML file.
extract:
  ruby: ./extractor.rb
  class: Freentonic::Providers::MyBank::Extractor

normalize:
  ruby: ./normalizer.rb
  class: Freentonic::Providers::MyBank::Normalizer
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
  extracted array — NOT the full response hash. If your extractor needs
  metadata like `result["count"]` alongside the batch, omit `batch_keys`
  and read the full response.
- **Use `_if_present` for multi-state login flows.** Banks remember
  sessions in various ways — email remembered, PIN skipped, straight to
  2FA. Use `wait_for_first_of` to detect which state, then
  `fill_if_present` / `click_if_present` so unused steps are no-ops.
- **Scope shared button IDs with `:has()`.** If a button ID like
  `#loginButton` exists on multiple pages, use
  `body:has(#emailInput) #loginButton` to only click it when the email
  form is present. Chrome supports `:has()` since v105.

## 3. Write the extractor

The extractor owns "I have credentials, give me a raw payload from the
provider API." It's plain Ruby — not a framework subclass — and is
instantiated by `Stages::Extract` with `.new`, then called with keyword
args:

```ruby
# my_bank/extractor.rb
module Freentonic
  module Providers
    module MyBank
      class Extractor
        def call(client:, credentials:, from_date:, stdout:, stderr:)
          stdout.puts "  Fetching accounts..."
          accounts = client.fetch_accounts
          stdout.puts "    → #{accounts.size} accounts"

          accounts.each do |account|
            id = account["id"]
            stdout.puts "  Fetching movements for #{account['name']}..."
            begin
              account["movements"] = client.fetch_movements(
                account_id: id,
                from_date:  from_date
              )
              stdout.puts "    → #{account['movements'].size} movements"
            rescue StandardError => error
              stderr.puts "    ✗ #{error.class}: #{error.message}"
              account["movements"] = []
            end
          end

          accounts
        end
      end
    end
  end
end
```

Return anything serializable to JSON — the framework will persist it
verbatim when you use `--dump-raw`.

**Error handling philosophy:** catch errors at the boundary of a single
product (so a failing card doesn't sink the whole run) but let
authentication errors bubble up — the user needs to log in again.

## 4. Write the normalizer

The normalizer takes the extractor's raw output and emits a universal
shape that HTTP receivers can consume. Subclass
`Freentonic::Normalizers::Base` and implement `#call(raw, context:)`:

```ruby
# my_bank/normalizer.rb
require "date"

module Freentonic
  module Providers
    module MyBank
      class Normalizer < Freentonic::Normalizers::Base
        def call(raw, context: {})
          {
            "source_tag" => "my_bank_push",
            "accounts"   => Array(raw).filter_map { |a| build_account(a) }
          }
        end

        private

        def build_account(a)
          {
            "external_id"    => "my_bank:#{a['id']}",
            "legacy_uids"    => ["my_bank:#{a['id']}"],
            "iban"           => a["iban"],
            "kind"           => kind_for(a),
            "bank_key"       => "my_bank",
            "name"           => a["name"] || "My Bank #{a['id']}",
            "currency"       => a["currency"] || "EUR",
            "balance_cents"  => cents(a["balance"]),
            "balance_source" => "my_bank:accounts",
            "metadata"       => { "my_bank_account_id" => a["id"] },
            "movements"      => Array(a["movements"]).filter_map { |mv| build_movement(a["id"], mv) }
          }
        end

        def build_movement(account_id, mv)
          date = parse_date(mv["date"])
          return nil unless date && mv["amount"]

          {
            "dedup_key"    => "my_bank:#{account_id}:#{mv['id']}",
            "date"         => date.strftime("%Y-%m-%d"),
            "amount_cents" => cents(mv["amount"]),
            "currency"     => mv["currency"] || "EUR",
            "description"  => mv["description"].to_s.strip,
            "raw_payload"  => { "my_bank_movement" => mv }
          }
        end

        def kind_for(a)
          case a["product_type"]
          when "credit_card" then "liability"
          when "loan"        then "liability"
          else                    "asset"
          end
        end

        def cents(amount)
          return nil if amount.nil?
          (amount.to_f * 100).round
        end

        def parse_date(str)
          return nil if str.to_s.empty?
          Date.parse(str)
        rescue Date::Error
          nil
        end
      end
    end
  end
end
```

### Universal payload shape

The output of every normalizer should follow the same broad contract so
receivers can consume any provider uniformly:

```ruby
{
  "source_tag" => "my_bank_push",
  "accounts" => [
    {
      "external_id"    => "my_bank:<id>",    # stable identifier
      "legacy_uids"    => ["my_bank:<id>"],  # alternate IDs for migration
      "iban"           => "...",             # or nil
      "kind"           => "asset" | "liability" | "investment",
      "bank_key"       => "my_bank",         # short tag per provider
      "name"           => "Human-readable",
      "currency"       => "EUR",
      "balance_cents"  => 123456,            # or nil if unknown
      "balance_source" => "my_bank:...",     # freeform provenance
      "metadata"       => { ... },           # anything you want
      "movements" => [
        {
          "dedup_key"    => "my_bank:<account>:<mvid>",
          "date"         => "YYYY-MM-DD",
          "amount_cents" => -1234,
          "currency"     => "EUR",
          "description"  => "...",
          "raw_payload"  => { ... }          # keep originals for debugging
        }
      ]
    }
  ]
}
```

The exact field set that receivers require is ultimately defined by the
ingest system you export to — but sticking close to this shape means
your provider plugs into any freentonic-aware receiver without
per-provider glue.

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

# Inspect the result and tweak normalizer.rb. Repeat the second command.
```

Use `--dump-normalized` + `--from-normalized` the same way if you want
to iterate on exporter config without re-running the normalizer.

## 6. Write tests

Two test files, both minimal. The first validates the credentials
mapping in `workflow.yml`; the second validates the normalizer against a
small hand-crafted fixture. Neither touches Chrome or the bank.

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
      workflow_context: {
        "cookie"     => "sid=abc",
        "csrf_token" => "tok-123"
      },
      stdout: StringIO.new,
      stderr: StringIO.new
    )

    assert_equal({ cookie: "sid=abc", csrf_token: "tok-123" }, credentials)
  end

  def test_raises_when_required_key_missing
    assert_raises(Freentonic::UserError) do
      source.extract_credentials(
        nil, workflow_context: {},
        stdout: StringIO.new, stderr: StringIO.new
      )
    end
  end
end
```

```ruby
# my_bank/test/my_bank_normalizer_test.rb
require "minitest/autorun"
require "freentonic"
require_relative "../normalizer"

class MyBankNormalizerTest < Minitest::Test
  def test_normalizes_a_basic_account_with_movements
    raw = [
      {
        "id"       => "acc-1",
        "name"     => "Checking",
        "iban"     => "ES00 1234 5678 9012 3456 7890",
        "currency" => "EUR",
        "balance"  => 1234.56,
        "product_type" => "current",
        "movements" => [
          { "id" => "mv-1", "date" => "2024-03-15", "amount" => -12.34, "description" => "Coffee" }
        ]
      }
    ]

    payload = Freentonic::Providers::MyBank::Normalizer.new.call(raw)
    assert_equal "my_bank_push", payload["source_tag"]

    acct = payload["accounts"].first
    assert_equal "asset",          acct["kind"]
    assert_equal 123_456,          acct["balance_cents"]

    mv = acct["movements"].first
    assert_equal "my_bank:acc-1:mv-1", mv["dedup_key"]
    assert_equal(-1234,                 mv["amount_cents"])
  end
end
```

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
- [ ] **Extractor catches per-product errors** but lets authentication
      errors bubble up so the user is prompted to re-login.
- [ ] **You've read every line of `workflow.yml`, `extractor.rb`, and
      `normalizer.rb` you wrote**, and you understand what each step
      does. Future contributors will copy from you.
- [ ] **No `eval`, no `send` with a user-controlled string, no
      `Object.const_get` with interpolation.** The framework's
      `load_client_ext` escape hatch requires explicit `module:` names
      exactly to avoid this.
- [ ] **Tests pass under `bundle exec rake test:<your_provider>`.**

## 8. Submission checklist

- [ ] Directory is snake_case and matches `config.key`.
- [ ] `workflow.yml` is version: 1 and parses through
      `Freentonic::WorkflowSchema.load(path)` without raising.
- [ ] `extractor.rb` and `normalizer.rb` are the only Ruby files in the
      provider dir (plus tests under `test/`).
- [ ] README.md's provider table in the repo root lists your new
      provider with status (`v1`, `experimental`, `deprecated`, …) and
      a one-sentence note.
- [ ] Pre-submission security walkthrough above.
- [ ] `bundle exec rake test` green locally.

## Reference providers

If you're unsure how to model something, read the existing providers —
they cover different styles of API and login flow:

- [`ing/`](../ing) — uses the legacy `genoma_api` shape. Credit card
  balance is recomputed from movement legs. Shows offset-based
  pagination, `derived_credentials` regex extraction from a cookie
  header, and a `wait_for_shadow_selector` + `enter_pin_pad` login.
- [`unicaja/`](../unicaja) — uses the Univia REST API. Shows a
  POST-form API client, multiple product types (cuentas + tarjetas +
  préstamos) in one extractor, credit-card filtering logic, and the
  `tokencsrf` header capture flow. Manual cursor pagination in the
  extractor for extended history.
- [`revolut/`](../revolut) — PKCE OAuth login, push-notification 2FA,
  cookie+header auth. Multi-product fetch (wallet, cards, vaults) with
  cursor-paginated transactions. Shows `capture_cookie_header` for
  httpOnly cookies.
- [`fintonic/`](../fintonic) — aggregator with Bearer token auth. Shows
  3-state login handling (`wait_for_first_of` + `_if_present`), SMS 2FA
  via `prompt_stdin_and_fill`, per-digit PIN entry via `secret(PIN[N])`
  indexing, `:has()` scoped clicks, manual offset pagination with
  `{page_offset}` (avoiding the reserved `{offset}`), and the
  `record_requests` + `dump_requests` investigation pattern. Also shows
  handling a flat category hash vs the more common nested array.

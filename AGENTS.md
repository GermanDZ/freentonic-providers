# AGENTS.md — freentonic-providers

Instructions for autonomous coding agents (Claude Code, Cursor, Aider, etc.)
working in this repository. **If you are a human, you probably want
[`docs/creating-a-provider.md`](docs/creating-a-provider.md) instead —
that doc is the technical reference this file delegates to.**

## Mission

This repository holds ready-to-use workflow YAMLs and provider plugins
for the [freentonic](https://github.com/GermanDZ/freentonic) framework.
Your job, when invoked here, is almost always one of:

1. **Add a new provider** (new bank / broker / utility).
2. **Fix or improve an existing provider** (API shape drift, extractor
   crashes, normalizer edge cases).
3. **Debug a failing run** against a live provider.

Every provider is a self-contained directory under the repo root:

```
<provider>/
├── workflow.yml      # declarative login + API client config
├── extractor.rb      # hits the API with captured credentials → raw payload
├── normalizer.rb     # raw payload → universal account/movement shape
└── test/
    ├── <provider>_extract_credentials_test.rb
    └── <provider>_normalizer_test.rb
```

The framework's `Stages::Extract` and `Stages::Normalize` load the Ruby
files by relative path from the YAML. There is no registry, no gemspec
change, no central wiring to edit.

## Before you start — questions to ask the user

**You should not start coding until you have concrete answers to the
questions below.** Providers are code that drives a real browser
against a real bank session; guessing leads to silent data corruption
and wasted human test cycles.

Ask these up front and stop to wait for answers. If the user has
already answered any of them in the conversation, skip that question.

### Core questions (ask every time)

1. **Which provider?** Full name, country, and the exact URL you'll
   log in at. Confirm there is not already a directory for it — run
   `ls -d */` and check the README table.
2. **Does the user have an account with this provider that they are
   willing to use for live smoke-testing?** If no, you can still build
   the YAML + code from docs / network captures, but you must mark the
   provider as `experimental` in the README and leave a note that
   end-to-end validation is pending.
3. **Does the user have a captured raw payload already (from a prior
   extract run, or a dump from their own tooling)?** If yes, ask them
   to save it at `/tmp/<provider>_raw.json` so you can iterate on the
   normalizer via `--from-raw` without triggering any bank login.
4. **Which API style does the provider use?** One of:
   - JSON-over-HTTPS with cookie auth (most common)
   - JSON-over-HTTPS with bearer token
   - Form-encoded POSTs with a CSRF token
   - Something else (GraphQL, proprietary binary, SOAP, …)

   **Preferred: ask the user for a HAR capture** of the login + a few
   representative API calls. See the "Getting a HAR capture" section
   below — this is the most efficient way to hand an agent everything
   it needs to write the workflow YAML and extractor in one shot. If
   the user has never exported a HAR before, walk them through it.

   If a HAR is not available, fall back to asking for:
   - The request URL
   - The request method
   - The request headers (minus the secret values — placeholder them)
   - The response body shape (JSON structure, not real data)
5. **What does the login flow look like?** Specifically:
   - Single-page DNI/user + password? Multi-step?
   - Does it use a PIN pad (on-screen digit buttons)?
   - Does it use a second factor (SMS, app push, OTP)?
     **2FA that requires a phone/app tap is a hard blocker for
     unattended runs — flag this and ask the user how they want to
     handle it.** (Usually: accept that the user must tap the phone,
     and wait in the pipeline with a long `wait_url` timeout.)
   - Are there any cookie consent banners / interstitials that must be
     dismissed?
6. **Which product types should this provider cover?** Current accounts?
   Credit cards? Loans/mortgages? Investments? For each, get a one-line
   description of how the provider distinguishes them in the API (a
   field name and its values).
7. **What date format does the provider's API use?** `YYYY-MM-DD`,
   `DD/MM/YYYY`, UNIX timestamp, …? The `date_format` key in the YAML
   needs to match exactly.

### Questions to ask before live testing

If the user wants you to actually run the pipeline against their live
account (not just write code against captured fixtures):

8. **Confirm the user is present at their keyboard** and ready to
   handle any 2FA prompts. You must not kick off a login flow and
   leave it hanging.
9. **Confirm the user has already stored secrets in their secret
   backend** (typically macOS Keychain). If not, the first run will
   prompt for each. Tell them which names you declared in `secrets:`
   so they know what's coming.
10. **Confirm the receiver endpoint** (if exporting via `--export http`).
    Full URL, token source, expected response shape.

### Red flags — stop and ask

- The provider requires installing a browser extension or native
  helper (frameworks can't drive those reliably). Flag and escalate.
- The provider's login page is a third-party SSO (Google, Apple, MS
  EntraID). Flag — these often have bot-detection that breaks CDP.
- The API requires request signing with a per-call HMAC or device
  attestation. Flag — this usually means reverse-engineering a mobile
  app, which is out of scope.
- The user asks you to commit secrets, real cookies, or production
  API responses containing PII. Refuse — point at the security
  checklist below.

## Getting a HAR capture from the user

**HAR (HTTP Archive) is the single most valuable artifact a user can
give you when building a new provider.** It's a JSON file that Chrome
and Firefox can export directly from DevTools; it contains every
request made during a browser session, with full URLs, headers, query
strings, request bodies, response bodies, and timings. This is exactly
what you need to:

- See every auth header the provider's frontend sends (so you can
  declare them in `auth_headers:`).
- See the exact URL shapes, query params, and response JSON structure
  of every API endpoint (so you can write `endpoints:` entries and
  `batch_keys:`).
- Trace which cookies are set at login, which path they're scoped to,
  and which ones the API actually reads.
- Determine the date format, pagination style, and error response
  shape without guessing.

This technique is how the ING and Unicaja providers in this repo were
originally built — it's the fastest path from "the user has an
account" to "I have a working YAML" by a wide margin.

### Asking the user for a HAR

Paste the following instructions to the user verbatim (Chrome is the
common case; Firefox is similar):

> 1. Open a fresh Chrome window and press **⌘⌥I** (macOS) or **F12**
>    (Windows/Linux) to open DevTools.
> 2. Click the **Network** tab.
> 3. Tick **Preserve log** at the top. Leave **Disable cache**
>    unticked — we want to see what a real session looks like.
> 4. Right-click inside the request list and choose **Clear** to
>    start from an empty log.
> 5. Navigate to the bank's login URL and log in normally. Complete
>    any 2FA.
> 6. Once you're on the dashboard, click around to trigger each kind
>    of data you want scraped: accounts list, movements for one
>    account, cards list, loans list, etc. Aim for one click per
>    endpoint.
> 7. Back in DevTools, right-click anywhere in the request list →
>    **Save all as HAR with content**.
> 8. Save the file somewhere **outside** this repository (e.g.
>    `~/Downloads/<bank>_login.har`) and tell the agent the path.

If the user is on Firefox: DevTools → Network → right-click → "Save
All As HAR". Safari requires enabling the Develop menu first and
using Web Inspector, but the HAR export is in the same place.

### Safety before you read the HAR

A HAR file with login traffic is **extremely sensitive**. It contains:

- Session cookies for an active logged-in bank session
- Bearer / CSRF / refresh tokens
- Everything the user typed into login forms (usually hashed or PIN-
  padded, but not always)
- Full API responses including real balances, IBANs, movement history,
  personal identifiers

**Hard rules for handling HAR files:**

- **Never copy a HAR file into this repository**, even temporarily.
  Not into `tmp/`, not into `fixtures/`, not into a gitignored path.
  The risk of a future `git add -A` committing it is not worth it.
- **Never paste HAR contents into a commit message, a test fixture,
  an issue comment, or a chat log** that will persist.
- **Never echo raw header values or response bodies back to the user
  in a chat transcript** that they might share publicly. If you need
  to reference a field, name it ("the `X-CSRF-Token` header exists")
  rather than quoting it.
- **Rotate sensitive credentials after using a HAR.** Tell the user:
  "I used your HAR to build the provider — once you confirm the
  workflow works, please log out of every active session and consider
  that cookie/token compromised." Most banks invalidate sessions on
  logout anyway, but the user should know.
- **Read the HAR in-place from wherever the user put it**, e.g.
  `~/Downloads/<bank>_login.har`. Use `ruby -rjson -e` one-liners or
  the Read tool against an absolute path outside the repo.

### Working with a HAR

A HAR file is a JSON document with a top-level `log.entries` array.
Each entry has `request` (method, URL, headers, postData) and
`response` (status, headers, content.text). Here are the queries that
extract the most useful views without dumping sensitive data:

```sh
HAR=~/Downloads/<bank>_login.har

# 1. List every unique request URL + method. This alone usually tells
#    you which endpoints you need to model.
ruby -rjson -e '
  entries = JSON.parse(File.read("'"$HAR"'"))["log"]["entries"]
  entries.map { |e| [e["request"]["method"], e["request"]["url"]] }.uniq.each { |m, u| puts "#{m} #{u}" }
' | sort -u

# 2. List the auth headers that appear on API calls (filter to your
#    provider's API host). Gives you the auth_headers: block directly.
ruby -rjson -e '
  entries = JSON.parse(File.read("'"$HAR"'"))["log"]["entries"]
  api = entries.select { |e| e["request"]["url"].include?("<api.host>") }
  api.flat_map { |e| e["request"]["headers"].map { |h| h["name"] } }.tally.sort_by { |_, n| -n }.each { |name, n| puts "%3d %s" % [n, name] }
'

# 3. Show the response body structure for one endpoint (pretty-print
#    top-level keys only, don't dump real data).
ruby -rjson -e '
  entries = JSON.parse(File.read("'"$HAR"'"))["log"]["entries"]
  hit = entries.find { |e| e["request"]["url"].include?("/accounts") }
  body = hit.dig("response", "content", "text")
  parsed = JSON.parse(body) rescue nil
  puts parsed.is_a?(Hash) ? parsed.keys : parsed.class
'
```

Use patterns like those — **never** `cat $HAR` or include the full
file in any tool output you plan to store. The goal is to extract the
*structure* of each request/response, not the contents.

### From HAR to workflow YAML

Walking the HAR in this order will give you a complete YAML draft:

1. Find the first request to the bank's domain → `phases.connect.navigate`.
2. Watch what URL you land on post-login → `phases.login.wait_url.includes`.
3. Look at the Cookie header on a successful API call → identifies
   which cookies you need to `capture_cookie_header` (the `host:` and
   `path:` scope come from the cookie's own domain/path attributes,
   visible in the Application tab in DevTools).
4. Look at other persistent request headers on the same call
   (`X-CSRF-Token`, `Authorization`, `tokencsrf`, `Origin`,
   `Referer`, …) → drives `auth_headers:` and any `capture_header`
   actions you need.
5. Group API URLs by shape (`/accounts`, `/accounts/{id}/movements`)
   → becomes `api_client.endpoints:`. For each endpoint note method,
   path template, and query params.
6. Check response bodies for the top-level key that holds the array
   (`items`, `movements`, `listaMovimientos`, …) → becomes
   `batch_keys:` and per-endpoint `response.extract_batch:`.
7. Check any date fields for format → becomes `date_format:`.
8. If the HAR shows multiple pages of one endpoint being fetched,
   note the pagination style (offset, cursor, page number) and limit.

You can usually produce a first-draft workflow YAML from a HAR in
under 15 minutes of reading. Hand it back to the user for review
before you write any Ruby — the YAML is cheap to change, the
extractor is not.

## Tools available in this repo

When running in an agentic environment, here are the commands you
should use. All are idempotent and safe to re-run.

```sh
# Run every provider's tests.
bundle exec rake test

# Run one provider's tests.
bundle exec rake test:<provider>

# Run one test file directly (fastest feedback loop during iteration).
ruby -I<provider> -I../freentonic/lib <provider>/test/<file>_test.rb

# Validate a workflow YAML loads through the framework's parser.
ruby -I../freentonic/lib -rfreentonic -e \
  'Freentonic::WorkflowSchema.load("<provider>/workflow.yml")'

# Run the full freentonic CLI against a provider (requires the sibling
# freentonic checkout at ../freentonic).
ruby -I../freentonic/lib ../freentonic/bin/freentonic \
  --workflow <provider>/workflow.yml \
  --through extract --dump-raw /tmp/<provider>_raw.json

ruby -I../freentonic/lib ../freentonic/bin/freentonic \
  --workflow <provider>/workflow.yml \
  --from-raw /tmp/<provider>_raw.json \
  --export json --export-path /tmp/<provider>_normalized.json
```

If `bundle exec` fails with a LoadError for `base64` or `csv`, the
user is on Ruby 3.4+ and hasn't run `bundle install` yet — tell them,
don't try to work around it.

## The development loop

Follow this exact order. It minimizes live-bank round-trips and
catches problems early.

### Step 1: scaffold

```sh
mkdir -p <provider>/test
touch <provider>/{workflow.yml,extractor.rb,normalizer.rb}
touch <provider>/test/<provider>_{normalizer,extract_credentials}_test.rb
```

### Step 2: write workflow.yml

Start from the skeleton in `docs/creating-a-provider.md § 2`. Fill in:

- `config.key` = provider directory name (snake_case)
- `secrets:` = one entry per piece of information the user must type
- `phases:` = login + capture steps derived from the user's DevTools
  capture (from question 5 above)
- `credentials:` = what downstream stages will see — `require:` and
  `map:` at minimum
- `api_client:` = derived from question 4
- `extract:` and `normalize:` = point at your sibling Ruby files,
  using the module name `Freentonic::Providers::<CamelCase>::<Kind>`

Validate it parses before writing any Ruby:

```sh
ruby -I../freentonic/lib -rfreentonic -e \
  'p Freentonic::WorkflowSchema.load("<provider>/workflow.yml").config'
```

### Step 3: write the extractor

Copy the contract from `docs/creating-a-provider.md § 3`. Key rules:

- **Catch errors at the boundary of a single product** (one account,
  one card) so a single failing product doesn't sink the run.
- **Let authentication errors bubble up.** They mean the user needs to
  log in again, and swallowing them leads to silent empty dumps.
- **Log every step to `stdout`** with the same `  ` indentation shape
  as the ING/Unicaja extractors. Users read this output to diagnose
  issues and pattern-match against known-good runs.
- **Return JSON-serializable data only.** The framework will persist
  your return value via `--dump-raw`, and if it can't JSON-round-trip
  you'll find out an hour into debugging.

### Step 4: write a minimal extractor test

Before touching a real bank, prove the extractor's *shape* is correct
with a fake API client:

```ruby
# <provider>/test/<provider>_extractor_test.rb
require "minitest/autorun"
require "stringio"
require "freentonic"
require_relative "../extractor"

class MyBankExtractorTest < Minitest::Test
  class FakeClient
    def fetch_accounts
      [{ "id" => "a1", "name" => "Checking", "balance" => 100.0 }]
    end
    def fetch_movements(account_id:, from_date:)
      [{ "id" => "m1", "date" => "2024-03-15", "amount" => -5.0, "description" => "Coffee" }]
    end
  end

  def test_populates_movements_per_account
    raw = Freentonic::Providers::MyBank::Extractor.new.call(
      client: FakeClient.new,
      credentials: { cookie: "fake" },
      from_date: Date.new(2024, 1, 1),
      stdout: StringIO.new, stderr: StringIO.new
    )
    assert_equal 1, raw.first["movements"].size
  end
end
```

Run it: `ruby -I<provider> -I../freentonic/lib <provider>/test/<provider>_extractor_test.rb`.

### Step 5: first live extract run

Now you need the user. Ask them to run (not you):

```sh
ruby -I../freentonic/lib ../freentonic/bin/freentonic \
  --workflow <provider>/workflow.yml \
  --through extract --dump-raw /tmp/<provider>_raw.json
```

They will see a Chrome window open, have to log in, possibly handle
2FA. When the command exits successfully, `/tmp/<provider>_raw.json`
holds the raw payload you can iterate against. Ask them to confirm the
file exists and to share the first few hundred characters so you know
the shape (without PII — ask them to scrub amounts/names/IDs).

**Do not attempt to drive the login flow yourself by shelling into
freentonic.** You do not have the user's secrets, you cannot answer an
SMS 2FA, and a botched login can temporarily lock the account.

### Step 6: write the normalizer against the raw dump

With `/tmp/<provider>_raw.json` in hand, write `normalizer.rb` and
iterate via `--from-raw` (no bank contact):

```sh
ruby -I../freentonic/lib ../freentonic/bin/freentonic \
  --workflow <provider>/workflow.yml \
  --from-raw /tmp/<provider>_raw.json \
  --export json --export-path /tmp/<provider>_normalized.json
```

Inspect `/tmp/<provider>_normalized.json`. Tweak. Repeat. This loop
runs in milliseconds and costs nothing.

Follow the universal payload shape in
`docs/creating-a-provider.md § 4`. The keys are not optional — they're
what every receiver downstream expects.

### Step 7: write a normalizer test

Extract a minimal hand-crafted fixture from the raw dump (two
accounts, three movements, covering every product kind the provider
supports). Put it inline in the test file — do not commit the real
dump. Assert on the shape of the output.

```sh
bundle exec rake test:<provider>
```

Must be green before you consider the work done.

### Step 8: end-to-end validation

Ask the user to run the full pipeline once against their real setup:

```sh
ruby -I../freentonic/lib ../freentonic/bin/freentonic \
  --workflow <provider>/workflow.yml \
  --export json --export-path /tmp/<provider>_full.json
```

If it produces the same shape as your `/tmp/<provider>_normalized.json`
from Step 6, you're done. If not, diff the two and iterate.

### Step 9: update the README table

Edit the provider table in the repo `README.md` to add a row:

```
| <Provider Name> | [`<provider>/`](<provider>) | v1 | One-line description. |
```

Pick the status honestly:
- `v1` — green tests + successful end-to-end run against a real account
- `experimental` — green tests, no live validation yet
- `deprecated` — still works but a better alternative exists

## Debugging

Pattern-match symptom → likely cause → next step:

### "Chrome did not respond on debug port after 45s"

The browser failed to launch. Usually one of:
- Chrome isn't installed at the expected path (macOS: `/Applications/Google Chrome.app/...`)
- A prior freentonic Chrome is still running with a stale profile
  → `pkill -f 'user-data-dir=.*freentonic'` and retry
- The port is taken by something else → pass `--port 9333`

### "workflow wait_url timed out waiting for ..."

Your pipeline expected to land on a URL that never showed up. Either:
- The login failed silently and the page is on an error state
- The URL fragment you're matching changed (banks redesign ~once/year)
- A cookie consent banner is blocking the flow

Have the user re-run with `--isolated` so Chrome starts clean. If it
works isolated but fails on the persistent profile, old session state
is interfering — bump the timeout or add a `navigate` to a logout URL
first.

### "workflow click could not find selector ..."

Selector drift. Ask the user to open DevTools on the live page and
inspect the element. For a systematic comparison of old vs. new DOM
shape, ask the user for a fresh HAR capture of the login flow (see
"Getting a HAR capture from the user" above) and diff the response
HTML bodies against what your selectors expect. Selectors inside
shadow DOM need `wait_for_shadow_selector` + `enter_pin_pad` or
`runtime_shadow_eval` style actions — `click`/`wait_for_selector`
don't pierce shadow roots by default (they use `deepQuery`, which
does, but only via the `deep` variants).

### "capture_header could not find ..."

The capture phase ran before the request carrying that header fired.
Fixes in order of preference:
1. Add `retries:` and `interval_seconds:` to the `capture_header`
   step (ING uses 3 retries × 1s)
2. Add a `wait_network_idle` step with `seconds: 3` before the
   capture
3. Add a synthetic `navigate` / `reload` to force the request

### The raw dump is empty or has 0 movements

Your API client is making requests but getting empty responses.
Usually authentication drift — the session cookie you captured is not
the one the API expects. Common causes:
- Wrong `host:` or `path:` in `capture_cookie_header` (the cookie you
  need is scoped to `/api/` but you captured `/`)
- The provider requires additional headers (Origin, Referer,
  X-Requested-With) that you didn't declare in `auth_headers`
- The provider rotates a CSRF token per session and you captured an
  expired one

Ask the user for a fresh HAR capture (see "Getting a HAR capture from
the user" above), find a successful API call in it, and compare its
full header set against what you declared in `auth_headers:`. A HAR
diff is the fastest way to spot a newly-required header without
guessing.

### Normalizer produces `[]` instead of accounts

Your extractor returned the right shape but your normalizer doesn't
know about a field. Add a debug `p` call at the top of `#call` (local
only, don't commit), rerun with `--from-raw`, check the structure.
Remove the `p` before handing back.

### `bundle exec rake test` passes but the CLI fails

You probably referenced a constant from one file inside another
without a `require_relative`. The test file loads both; the CLI loads
only what the YAML declares. Check: every `XXXXX::Something` reference
in `normalizer.rb` is either stdlib, from `Freentonic::`, or backed by
a `require_relative` at the top of the file.

### The HTTP exporter returns 404 on a URL with a path

Re-read the URL you typed. Freentonic refuses bare-host URLs with a
hint, but valid-looking wrong paths pass through. Double-check the
receiver's spec.

## Safety rails — things you must never do

- **Never commit secrets, real cookies, real tokens, or production
  API responses that contain personal data.** Not in fixtures, not in
  comments, not in commit messages, not "just for a minute to see if
  it works." If a value is sensitive, it goes in the secret backend
  or gets hand-crafted for the test.
- **Never commit a HAR file or any derivative of one** (a cherry-
  picked request, a sanitized-looking header dump, a pretty-printed
  response body). HAR files live *outside* the repo, are read in
  place, and are treated as burn-after-use. See "Getting a HAR
  capture from the user" for the full handling rules.
- **Never add a test fixture that is a verbatim bank response** —
  always strip amounts, names, IDs, IBANs, transaction descriptions
  down to placeholder values. The public repo is readable by anyone.
- **Never drive a live bank login yourself.** You don't have the
  user's secrets and you can't answer 2FA. Always ask the user to
  execute the command that touches the bank.
- **Never use `eval`, `send` with a user-controlled string, or
  `Object.const_get` off a string you interpolated.** The
  framework's security invariants (documented in `SECURITY.md` of
  the freentonic repo) must hold for every provider too.
- **Never commit to a branch without running `bundle exec rake test`
  first.** CI will catch you, but wasted cycles cost trust.
- **Never modify the freentonic framework itself from here.** If you
  think you need a new workflow action, a new credential-capture
  primitive, a new exporter, or a new secret backend, **do not hack
  around it with Ruby glue in the provider directory**. Stop, and
  produce an Issue + PR draft against the freentonic framework repo
  following the "Proposing new framework capabilities" section below.
- **Never clone / fork / fetch from a freentonic-providers repo you
  don't know.** Workflow YAMLs are code — they can navigate Chrome
  with the user's session cookies and load arbitrary Ruby. Only run
  YAML you or the user wrote.

## Proposing new framework capabilities

Sometimes, partway through building a provider, you will discover
that the provider needs something **the framework doesn't support
declaratively yet**. Examples:

- The login page uses a drag-to-unlock slider, and there is no
  `drag` action in `BrowserWorkflowRunner`.
- The provider sends an OTP that the user must paste into a pop-up,
  and there is no `prompt_user_for_value` action that blocks on
  stdin mid-pipeline.
- The API uses websocket streaming instead of REST, and
  `Freentonic::ApiClient` only knows GET/POST.
- The user wants to export to an S3 bucket, and there is no `s3`
  exporter.
- The API needs a custom request signing (HMAC over body +
  timestamp) that `api_client.auth_headers:` can't express.

**When you hit one of these, do NOT solve it by writing custom Ruby
inside the provider directory.** A provider that monkey-patches the
framework or shells out from `extractor.rb` to do "framework-ish"
work is a bug — it bypasses the security invariants, the test suite,
and the shared API that keeps providers interoperable.

Instead, produce an **Issue draft + PR draft** targeting the
[freentonic framework repo](https://github.com/GermanDZ/freentonic),
hand both to the user in your chat output, and stop work on the
provider until the capability lands upstream (or the user tells you
to ship a limited workaround explicitly).

### How to recognize "this needs a framework change"

You are probably looking at a framework gap if any of these are true:

- Your provider's `extractor.rb` is more than ~80 lines and most of
  it is plumbing (HTTP, retries, auth signing, parsing), not
  provider-specific logic.
- You'd need to `require "net/http"` (or similar) directly in a
  provider file and reimplement something `Freentonic::ApiClient`
  almost-but-not-quite does.
- You'd need a step in `workflow.yml` whose `action:` value doesn't
  exist in `../freentonic/lib/freentonic/browser_workflow_runner.rb`
  and no existing action composes to what you need.
- The capability would be useful to **more than one** provider. If
  only your provider would ever use it, it might belong in
  `extractor.rb` after all — ask the user.
- You find yourself wanting to call a private method of a framework
  class.

If you're unsure, err on the side of proposing a framework change.
Upstream review catches mistakes that provider-level workarounds
bury.

### The issue draft template

Produce this as a single markdown block in your chat output, ready
for the user to paste into `gh issue create` or the GitHub UI. Fill
in every `<...>` placeholder — no TODOs, no guesses.

Note: the outer fence below uses four backticks so nested YAML
blocks with three-backtick fences render correctly on GitHub. When
you paste the issue body into `gh issue create --body`, use the
**inner** text without the outer ```` ```markdown ```` wrapper.

````markdown
## Summary

Add support for `<one-sentence description of the capability>` to
freentonic so providers can express it declaratively instead of
writing bespoke Ruby.

## Motivation

While building the `<provider>` provider in freentonic-providers, I
needed to `<describe what the provider's login / API requires>`.
There is no way to express this in the current workflow YAML or
`Freentonic::ApiClient` DSL — the closest existing primitive is
`<name the nearest existing action/feature>`, which falls short
because `<explain the gap in one sentence>`.

At least `<N>` providers are likely to need this (provided examples:
`<provider-a>`, `<provider-b>`, …) so it belongs in the framework
rather than in any one provider's extractor.

## Proposed declarative shape

A workflow YAML using the new capability would look like:

```yaml
phases:
  login:
    - action: <new_action_name>
      <key1>: <value1>
      <key2>: <value2>
      # Explain each key in one line:
      #   <key1> — <what it does>
      #   <key2> — <what it does>
```

Or (for api_client / exporter / secrets changes, pick the right shape):

```yaml
api_client:
  <new_key>:
    <sub_key>: <value>
```

## Alternative considered

`<What else I thought about and why I rejected it.>` Usually one of:
composing existing actions, moving the logic into `extractor.rb`,
adding a new exporter instead of a workflow action, etc.

## Security considerations

- `<Does this introduce a new way for YAML authors to execute code?>`
- `<Does it accept user-controlled strings that reach shell / eval
  / const_get / JS injection? If so, what sanitization is required?>`
- `<Does it leak secrets to stdout/stderr/logs that didn't leak before?>`
- `<Does it preserve the existing invariants listed in SECURITY.md?>`

## Scope of change (estimated)

- New file(s): `<list>`
- Modified file(s): `<list>`
- New tests: `<list>`
- Documentation updates: README.md action table, SECURITY.md if
  relevant.

## Discovered from

Building `freentonic-providers/<provider>` — see the draft workflow
YAML in `<link to branch or paste below>`.
````

### The PR draft template

A PR description the user can paste into `gh pr create`. Keep the
title short (≤70 chars); put the detail in the body.

````markdown
## Summary

- Add `<new_action_name>` workflow action for `<what it enables>`.
- Wire it into `BrowserWorkflowRunner#execute_step` under
  `when "<new_action_name>"`.
- Add unit tests covering `<happy path>` and `<edge case>`.

Closes #<issue number from the issue draft above>.

## Declarative shape

```yaml
<paste the YAML snippet from the issue draft>
```

## Implementation notes

- The new action delegates to `<private helper method>` which wraps
  `<the CDP command / HTTP call / whatever>`.
- Arguments are passed through `JSON.generate` before being injected
  into any `Runtime.evaluate` expression, preserving the framework's
  JS injection invariant (see SECURITY.md).
- No new runtime dependencies — implementation uses `<stdlib bits>`.

## Test plan

- [ ] New minitest cases in `test/browser_workflow_runner_test.rb`
      exercise the action against a `FakeSession`.
- [ ] `bundle exec rake test` green.
- [ ] Smoke-tested end-to-end against
      `freentonic-providers/<provider>/workflow.yml` on a real
      account (see the issue for the live-run transcript).

## Out of scope

- `<adjacent things I did NOT change, to make the review boundary clear>`
````

### Files to touch (cheat sheet)

Map the capability class → files to mention as "modified/added" in
the PR draft:

| Kind of capability             | Framework files to change                                |
| ------------------------------ | -------------------------------------------------------- |
| New browser workflow action    | `lib/freentonic/browser_workflow_runner.rb` (add `when` branch) + `test/browser_workflow_runner_test.rb` |
| New credential capture step    | Same as above — capture actions live in `BrowserWorkflowRunner` |
| New api_client DSL macro       | `lib/freentonic/api_client.rb` (class-level DSL block) + `test/api_client_test.rb` + YAML binding in `lib/freentonic/workflow_schema.rb#build_api_client_class` |
| New exporter                   | `lib/freentonic/exporters/<name>.rb` + `test/exporters_test.rb` + register call loaded from `lib/freentonic.rb` |
| New secret backend             | `lib/freentonic/secrets/<name>.rb` + `test/secrets_test.rb` + register call loaded from `lib/freentonic.rb` |
| New stage (rare)               | `lib/freentonic/stages/<name>.rb` + `lib/freentonic/engine.rb` STAGE_ORDER/STAGE_CLASSES + new CLI flag + new test |
| Change to workflow YAML schema | `lib/freentonic/workflow_schema.rb#validate!` + `test/workflow_schema_client_test.rb` + README reference |

If you cannot locate the right file within 5 minutes of searching
the framework source, stop and ask the user — you may be proposing
something that cuts across more than one subsystem, and the user
should weigh in before you draft the PR.

### After you hand the drafts over

- **Do not open the issue or the PR yourself.** The user reviews the
  draft and decides whether to file it as-is, revise it, or reject
  the proposal entirely. You do not have permission to make changes
  to the framework repo from inside freentonic-providers.
- **Do not commit a workaround to the provider while you wait.** If
  the user explicitly authorizes a temporary workaround (e.g. "ship
  an extractor.rb hack now, remove it when the PR lands"), add a
  `TODO(upstream #<issue>):` comment next to the hack so it's easy
  to find and remove later.
- **If the user tells you to proceed without an upstream fix**,
  treat that as an override: note it in the PR description (if/when
  there is one for this provider), and make sure the provider's
  `README` entry reflects the `experimental` status with the
  dependency called out.

## When to stop and ask

Stop and ask the user — don't guess — when you hit any of:

- A login flow requires 2FA and you don't know how the user wants to
  handle it.
- The provider returns an error response you don't recognize, and
  retrying with the same cookies reproduces it.
- You've iterated on the normalizer three times and the shape still
  doesn't match what you expected — you're probably wrong about the
  API, not the normalizer.
- A test requires a fixture larger than ~30 lines. That's a sign
  you're testing too much; break it up or ask which case is most
  valuable.
- The user asked for a feature you don't think belongs in a provider
  (new workflow action, new exporter, new secret backend). That work
  happens in the freentonic framework repo — see "Proposing new
  framework capabilities" for how to produce the Issue + PR drafts.
- Security rail ambiguity: "is this field PII?", "is this token
  rotated or permanent?", "can I commit this error message?". When in
  doubt, assume yes to PII and ask.

## Completion criteria

A provider is ready to ship when **all** of these are true:

- [ ] `<provider>/workflow.yml` parses through
      `Freentonic::WorkflowSchema.load` without raising.
- [ ] `<provider>/extractor.rb` is present and handles per-product
      errors gracefully.
- [ ] `<provider>/normalizer.rb` is present and emits the universal
      payload shape.
- [ ] `bundle exec rake test:<provider>` is green.
- [ ] `bundle exec rake test` (full suite) is green — you haven't
      broken any other provider.
- [ ] The README table has a new row with accurate status.
- [ ] No secrets, PII, or verbatim bank responses anywhere in the
      diff.
- [ ] End-to-end run against the live provider succeeded OR the
      status is marked `experimental` with a note on what was
      validated against a captured dump.
- [ ] You've re-read every file you created. Future maintainers will
      copy from you.

When those are all satisfied, summarize what you built, report which
commands you ran, and hand the diff back to the user for review. Do
not commit or push — the user will review and commit themselves
unless they've explicitly told you otherwise.

## Reference: where to look when you're stuck

| Question                                     | File                                                    |
| -------------------------------------------- | ------------------------------------------------------- |
| How do I get a HAR capture from the user?    | "Getting a HAR capture from the user" section above     |
| I need a new action / exporter / backend — what now? | "Proposing new framework capabilities" section above |
| What does the workflow YAML look like?       | `docs/creating-a-provider.md` § 2                       |
| What does an extractor look like?            | `ing/extractor.rb`, `unicaja/extractor.rb`              |
| What does a normalizer look like?            | `ing/normalizer.rb`, `unicaja/normalizer.rb`            |
| What does a test look like?                  | `ing/test/ing_normalizer_test.rb`                       |
| What workflow actions exist?                 | `../freentonic/lib/freentonic/browser_workflow_runner.rb` (search `case action`) |
| How does the HTTP client DSL work?           | `../freentonic/lib/freentonic/api_client.rb`            |
| How are credentials validated/mapped?        | `../freentonic/lib/freentonic/source.rb`                |
| How does the pipeline dispatch?              | `../freentonic/lib/freentonic/engine.rb` + `stages/`    |
| Security invariants + threat model           | `../freentonic/SECURITY.md`                             |

If you've read the relevant reference file and still don't know what
to do, stop and ask the user. Guessing at a bank-facing integration
is a good way to lock an account or leak PII.

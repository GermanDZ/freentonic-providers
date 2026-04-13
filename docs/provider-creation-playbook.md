# Procedure: Creating a New Freentonic Provider

Derived from the Revolut provider development session (2026-04-12). This document captures what worked, what didn't, the problems encountered, and how they were solved — intended as a reusable playbook for creating future providers.

## Tooling

This repo includes tools that automate the mechanical parts:

| Command | What it does |
|---|---|
| `rake new[provider_name]` | Scaffold directory + stub files with best-practice patterns baked in |
| `rake har[path/to/file.har]` | Analyze a HAR file — lists endpoints, auth headers, login flow, pagination |
| `rake har[path,api.host.com]` | Same, filtered to a specific API host |

Shared helpers (`lib/freentonic/providers/helpers.rb`) provide `safe_fetch`, `cents()`, `parse_date()`, and `parse_timestamp_ms()` — already included in scaffolded files.

---

## Overview

Building a provider took ~75 minutes from zero to working end-to-end. The time was distributed as:

| Phase | Time | Notes |
|---|---|---|
| Exploration (read existing code) | ~15 min | Read ING, Unicaja, AGENTS.md, creating-a-provider.md |
| HAR capture + analysis | ~10 min | User captures, agent analyzes URL patterns |
| Scaffold + first workflow | ~5 min | Directory, stub files, initial YAML |
| Login flow iteration | ~30 min | **Most time-consuming** — 7 attempts to get right |
| Extractor | ~5 min | Mostly worked first try |
| Normalizer | ~10 min | 3 fixes needed from real data inspection |

**The login flow is where all the pain is.** Everything else is mechanical once you have a working session and a raw dump.

---

## Step-by-Step Procedure

### Step 1: Gather Information (before writing any code)

**Ask the user:**
1. Do you have a live account for testing?
2. Which product types to cover? (accounts, cards, loans, savings, crypto)
3. Can you capture a HAR file?

**HAR capture instructions** (give to user verbatim):
1. Open Chrome → DevTools (Cmd+Option+I) → Network tab
2. Tick "Preserve log"
3. Clear the log
4. Navigate to the bank login URL and log in normally
5. Once on dashboard, click through each data section (accounts, cards, transactions, savings)
6. Right-click in request list → "Save all as HAR with content"
7. Save OUTSIDE the repository (e.g. `~/Downloads/<bank>_login.har`)

**What went well:** HAR analysis revealed URL patterns, auth headers, pagination style, and the SSO login flow — even without response content.

**What went wrong:** The HAR was saved without response content (Chrome's "with content" wasn't selected). This made response shapes unknown.

**Lesson learned:** HAR without content is still 80% useful. URL patterns + headers + query params tell you most of what you need. Response shapes will come from `--dump-raw` later anyway.

### Step 2: Analyze the HAR

Run the HAR analyzer:

```sh
rake "har[~/Downloads/my_bank_login.har,api.mybank.com]"
```

This produces a structured report with:
- All unique API endpoints (method, path, status)
- Custom/auth headers ranked by frequency
- Login flow POST requests (keys only, never values)
- Pagination patterns from transaction endpoints
- Whether response content was captured

**What to identify from the report:**
- Login URL and post-login redirect URL
- Auth mechanism (cookies, bearer token, custom headers)
- API base URL and endpoint paths
- Pagination style (offset, cursor, timestamp)
- Date format in query params

**What went well:** From Revolut's HAR we identified PKCE OAuth flow, cursor-based pagination (`to=<unix_ms>&count=50`), and the full API endpoint inventory.

**What went wrong:** Auth mechanism was unclear — no Cookie or Authorization headers visible. Turned out to be httpOnly cookies that HAR didn't capture.

**Lesson learned:** If auth mechanism is unclear from HAR, capture everything (cookies + custom headers) during live run and prune later. Don't guess.

### Step 3: Scaffold the Directory

```sh
rake new[my_bank]
```

This generates the full directory with best-practice patterns already baked in:
- `workflow.yml` with `_if_present` login pattern and `wait_network_idle` for session handling
- `extractor.rb` with `safe_fetch` helper included
- `normalizer.rb` with `cents()` and `parse_date()` helpers included
- Test files with working boilerplate

The scaffolded tests pass immediately (`rake test:my_bank`), so you can iterate from a green baseline.

### Step 4: Write the Workflow YAML — Login Flow

**THIS IS THE HARDEST PART.** Budget the most time here.

#### Critical rules (learned the hard way):

**Rule 1: NEVER guess CSS selectors.** Ask the user for a screenshot or DOM snippet of the login page BEFORE writing any selectors. During Revolut development, 3 out of 7 attempts failed due to wrong selectors.

**Rule 2: Handle THREE login states from day one:**
1. **Fresh login** — full credential entry
2. **Remembered credentials** — partial (e.g. email remembered, only passcode needed)
3. **Already logged in** — session persists from previous run

Chrome's system profile keeps sessions alive. The second run WILL find the user already logged in.

**Rule 3: Use `_if_present` actions as the default pattern:**
```yaml
login:
  - action: click_if_present
    selector: "button[aria-label='Continue with email']"
  - action: fill_if_present
    selector: "input[type='email']"
    value: "secret(USER_EMAIL)"
  - action: click_if_present
    selector: "button[type='submit']"
  - action: fill_if_present
    selector: "input[type='password']"
    value: "secret(USER_PASSCODE)"
```

This pattern naturally handles all three states — if already logged in, every action is a no-op.

**Rule 4: Use `wait_network_idle` instead of `wait_for_first_of` for state detection.** `wait_for_first_of` requires finding a CSS selector that uniquely identifies the logged-in state, which is surprisingly hard. `wait_network_idle seconds: 3` works regardless of state.

**Rule 5: Check if passcodes auto-submit.** Look at HAR timing between the passcode POST and the next step. If the gap is <2 seconds, it auto-submits after N digits. Do NOT add a "Continue" click after filling the passcode.

**Rule 6: For 2FA wait, use specific URLs:**
```yaml
# BAD — matches too broadly, can match before 2FA is complete
- action: wait_url
  includes: "app.revolut.com"

# GOOD — matches only the actual post-login page
- action: wait_url
  includes: "app.revolut.com/home"
  timeout: 300
```

**Rule 7: Know what framework actions exist.** Only these `_if_present` variants exist:
- `click_if_present` (selector-based)
- `fill_if_present` (selector-based)

These do NOT exist:
- ~~`click_text_if_present`~~ — use `click_if_present` with a specific selector instead
- ~~`:has-text()` pseudo-selector~~ — Playwright-only, not valid CSS. The framework uses standard `querySelector`.

**What went well:** Once we switched to the `wait_network_idle` + `_if_present` pattern, the login worked for all three states without any further changes.

**What went wrong (Revolut-specific):**
1. SSO page defaults to phone number, not email — needed `button[aria-label='Continue with email']` click first
2. Passcode auto-submits — the "Continue" click after passcode caused a timeout
3. `wait_url includes: "app.revolut.com"` matched before 2FA was approved (SSO was on same domain briefly)
4. `click_text_if_present` and `:has-text()` don't exist in the framework

### Step 5: Capture Credentials

Start by capturing everything, then prune:
```yaml
capture_credentials:
  - action: capture_cookie_header
    host: "app.example.com"
    path: "/api/"
    as: cookie
  - action: capture_header
    name: "X-Custom-Header"
    as: custom_header
    retries: 5
    interval_seconds: 2
```

**What went well:** Revolut's auth turned out to be httpOnly cookies (9 cookies captured) + `x-device-id` header. Both were captured successfully on the first successful login attempt.

**Lesson learned:** `capture_cookie_header` uses CDP's `Network.getAllCookies` which captures httpOnly cookies that are invisible in HAR exports. Always try cookie capture first.

### Step 6: First Live Run — `--dump-raw`

Ask the user to run:
```sh
bin/freentonic --workflow <provider>/workflow.yml \
  --through extract --dump-raw /tmp/<provider>_raw.json
```

**This is the most important artifact.** It reveals:
- Actual response shapes (field names, nesting)
- Amount units (cents vs major units)
- Date formats (Unix ms, ISO 8601, DD/MM/YYYY)
- Pagination cursor field names
- Which endpoints require extra params

**What went wrong (Revolut):**
1. `bank-accounts/account-details` returned 400: `"query param 'currency' not defined"` — HAR didn't show this param was required
2. Vault balance is a Hash (`{"amount": 0, "currency": "EUR"}`), pocket balance is a plain integer (cents)
3. Transaction amounts are already in minor units (cents) — different from ING/Unicaja which use major units

**Lesson learned:** NEVER write the normalizer before inspecting the raw dump. Amount units, date formats, and nesting structures are impossible to guess and vary wildly between providers.

### Step 7: Write the Extractor

Follow the contract from `docs/creating-a-provider.md § 3`:
```ruby
def call(client:, credentials:, from_date:, stdout:, stderr:)
```

**Key patterns:**
- **Per-product error handling:** `safe_fetch` wrapper — one failing product shouldn't sink the run
- **Pagination in the extractor, not the YAML** — for cursor-based pagination, implement the loop manually (like Unicaja's pattern)
- **Safety cap:** `MAX_TRANSACTIONS_SAFETY_CAP = 10_000` to prevent runaway pagination
- **Always log progress:** `stdout.puts "  Fetching X..."` → `stdout.puts "    → N items"`

**Pagination gotcha (Revolut):** The `to` cursor parameter must be declared in the endpoint YAML params AND passed by the extractor. If you forget to add it to the YAML, the framework silently drops it and you get the same first page repeatedly — pagination appears to work (no errors) but only returns 1-2 pages.

### Step 8: Write the Normalizer (iterate with `--from-raw`)

This is the fast loop — no bank contact needed:
```sh
bin/freentonic --workflow <provider>/workflow.yml \
  --from-raw /tmp/<provider>_raw.json \
  --export json --export-path /tmp/<provider>_normalized.json
```

**Key patterns:**
- **`cents()` helper must handle multiple types:**
  - `Numeric` → may already be in cents (Revolut) or in major units (ING/Unicaja)
  - `Hash` → `{"amount": 12.34, "currency": "EUR"}`
  - `String` → `"12,34"` (comma as decimal separator)
- **IBAN may be deeply nested** — Revolut: `details.accounts[0].iban`, not top-level
- **Date parsing must handle multiple formats** — Unix ms timestamps, ISO 8601, DD/MM/YYYY

**What went well:** Once we had the raw dump, normalizer iteration was fast — each `--from-raw` run takes milliseconds.

### Step 9: Write Tests

Two mandatory test files:
1. **Credential extraction test** — validates workflow YAML maps context to credentials
2. **Normalizer test** — hand-crafted fixtures matching real data shapes (amounts in correct units, correct nesting)

Update test fixtures after inspecting real data shapes. Initial guesses will be wrong.

### Step 10: End-to-End Validation

Full pipeline:
```sh
bin/freentonic --workflow <provider>/workflow.yml --lookback <days> \
  --export json --export-path /tmp/<provider>.json
```

Verify: account count, balance matches what user sees, movements date range covers lookback.

### Step 11: Update README + Run Full Suite

```sh
bundle exec rake test  # all providers, not just yours
```

---

## Common Pitfalls (ranked by frequency during Revolut development)

| # | Pitfall | Frequency | Fix |
|---|---|---|---|
| 1 | Wrong CSS selectors | 3 times | Ask for screenshot/DOM BEFORE coding |
| 2 | Missing framework action | 2 times | Check ING workflow for valid actions |
| 3 | Session persistence not handled | 2 times | Use `_if_present` pattern from day one |
| 4 | Amount units wrong | 1 time | Inspect `--dump-raw` before normalizer |
| 5 | Pagination param not in YAML | 1 time | Cursor params must be declared in endpoint YAML |
| 6 | Auto-submit not detected | 1 time | Check HAR timing between steps |
| 7 | Nested response structure | 1 time | Always inspect actual response, don't assume flat |
| 8 | `wait_url` too broad | 1 time | Use specific path, not just domain |
| 9 | Invalid CSS pseudo-selector | 1 time | Only use standard CSS, no `:has-text()` |
| 10 | API endpoint needs extra params | 1 time | Error message is the clue — read it |

---

## What Would Make This Faster Next Time

1. **Ask for login page screenshot BEFORE any selectors** — saves 2-3 failed iterations (~10 min)
2. **Use the `wait_network_idle` + `_if_present` template from the start** — don't try `wait_for_first_of` for session detection
3. **Always `--dump-raw` before normalizer** — never assume amount units or nesting
4. **Check framework action inventory upfront** — reference ING's workflow.yml for valid actions
5. **Declare ALL endpoint params in YAML** — including pagination cursors

With these optimizations, the next provider should take ~45 min instead of ~75 min — mostly saving time on login flow iteration.

---

## Reference: Revolut Provider Final State

The complete working implementation serves as a reference for future providers:

- `revolut/workflow.yml` — handles 3 login states, PKCE OAuth, app push 2FA, cookie+header auth
- `revolut/extractor.rb` — multi-product fetch (wallet, bank details per currency, cards, vaults), cursor-paginated transactions with safety cap
- `revolut/normalizer.rb` — handles integer cents (pockets/transactions), Hash amounts (vaults), Unix ms dates, deeply nested IBAN
- `revolut/test/` — credential extraction + normalizer tests with real data shapes

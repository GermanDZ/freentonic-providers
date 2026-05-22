# ING API notes

Distilled findings from the unified `/search` migration. Each section
documents a non-obvious behavior of `api.ing.ingdirect.es` that the
extractor and workflow YAML must honor. The code at HEAD already
encodes everything here — this doc is for the next person debugging
the path (or building a similar v2-only provider) so they don't have
to re-discover.

## Endpoints in play

```
GET  https://api.ing.ingdirect.es/position-keeping
POST https://api.ing.ingdirect.es/v2/products/transactions/search
GET  https://ing.ingdirect.es/genoma_api/rest/sca/documentation   (legacy, SCA only)
GET  https://api.ing.ingdirect.es/saf/tpa/accesstoken/synchronize (post-SCA token refresh)
```

`/position-keeping` returns the product list (and balances).
`/search` is the only data-fetching endpoint we use — it covers
checking, savings, and credit-card products in a unified shape.

## Stable transaction id: `v2-seq:<productId>:<transactionSequence>`

Every row carries:

```json
{ "transactionId": { "productId": "<uuid>", "transactionSequence": <int> } }
```

That pair is stable across refetches of the same posting — even when
the description gets enriched as the row transitions through
pending lifecycle stages, and even across login sessions. The
extractor emits `v2-seq:<productId>:<seq>` as the canonical
source-id, which the framework hashes into the `txn_<hex>` row id.

Do **not** use `transactionLocalUUID`. It looks stable in a single
response but is re-encrypted per request — same row, different
fetches produce different `transactionLocalUUID` values. This was
the original dup-bug source on the retired legacy `/movements`
endpoint.

Rows missing `transactionId` get `uuid: nil` from `v2_stable_uuid`
and the normalizer drops them downstream. Preferable to losing one
row than synthesising an unstable fallback id.

## Four silent-failure modes on `/search`

All four return HTTP 200 with `transactions: []` (or a wrong-format
body) rather than an error status. None of them is hinted at in
ING's response — diagnosing requires comparing the actual outbound
request to a known-good one.

### 1. Missing `X-XSRF-TOKEN` → empty body

`/search` is a POST and ING enforces CSRF on state-changing
methods. The XSRF-TOKEN cookie value must echo as an
`X-XSRF-TOKEN` header on every api-host request. GETs ignore it
harmlessly.

Wired declaratively in `ing/workflow.yml`:

```yaml
derived_credentials:
  xsrf_token:
    from: cookie
    regex: 'XSRF-TOKEN=([^;]+)'
    capture: 1

auth_headers:
  - host: "api.ing.ingdirect.es"
    headers:
      X-XSRF-TOKEN: "{xsrf_token}"
```

The cookie capture targets `ing.ingdirect.es/genoma_api/rest/` and
includes the XSRF-TOKEN cookie because its domain attribute scopes
to the parent (`.ingdirect.es`). The extractor's `call()` runs a
startup check that warns loudly if the cookie regex misses, in
case ING ever re-scopes it to `api.ing.ingdirect.es` only.

### 2. `Content-Type: application/json;charset=UTF-8` → empty body

ING silently rejects JSON requests whose Content-Type carries the
`;charset=UTF-8` suffix even though it's RFC-tolerated. Use the
bare media type. RFC 8259 section 11 explicitly says no charset
parameter is defined for `application/json`, so bare is
spec-correct anyway.

Fixed upstream in `freentonic` v0.10.1 — `define_post(json:)` no
longer appends the suffix. `raw_request` always used the bare form.

### 3. Investment-product UUID poisons multi-UUID batches with 401

The ING product type for "Cuenta de valores" (brokerage cash
sweep) returns HTTP 401 from `/search` on its own — and including
its UUID in a multi-UUID `uuids: [...]` array makes the entire
call 401, even though every sibling UUID is fine on its own.

Exclude `kind == "investment"` upfront in the fetchable list. The
investment account still flows through to the normalizer with the
balance from `/position-keeping`; just no transactions.

The bank's SPA presumably uses a different endpoint for brokerage
transactions. Worth probing if a future use case needs them.

### 4. Multi-UUID `uuids` triggers a sign-stripped "summary" format

The most expensive quirk to find. Same endpoint, same headers,
same body shape — but the response format depends on the `uuids`
array length:

| `uuids` array | Format |
|---|---|
| single-element | **Detailed**: signed string amounts (`"-NN.NN"`), raw padded merchant descriptions identical to ING's XLS export. |
| multi-element | **Summary** on CC rows: amounts arrive absolute (sign stripped), descriptions humanized with Spanish prefixes (`Pago en X` for purchases, `Abonos Varios X` for refunds). Asset rows in the same response stay signed — the format quirk affects credit-card rows only. |

Verified by issuing identical single-UUID and multi-UUID `/search`
calls against the same captured Bearer + ESC + cookie and the
same date window. The same `transactionSequence` came back signed
and raw in the single-UUID call, sign-stripped and humanized in
the multi-UUID call.

**Fix:** one `/search` POST per product UUID, never batched.
`fetch_v2_search_into_products` iterates per product. Costs N
extra HTTP requests per sync, but the response data lands
canonical with no client-side sign heuristic.

A previous attempt to flip signs based on the `Pago en `
description prefix worked but was treating a symptom; the
per-UUID switch treats the cause.

## SCA elevation boundary

`/search` rejects ranges older than ~90 days from a low-LoA
Bearer (signaled by `moreSca: true` in the response envelope; the
server truncates the response at the boundary rather than
erroring).

`SCA_ELEVATION_LOOKBACK_DAYS` in `ing/extractor.rb` is set to 90.
When lookback exceeds the threshold AND a remote prompt store is
available, the extractor runs the PSD2 handshake against the
genoma legacy host (`/genoma_api/rest/sca/documentation` GET →
operator approves on phone → PUT) and refreshes the Bearer via
`/saf/tpa/accesstoken/synchronize`. The new high-LoA Bearer is
rotated onto the client scoped to `api.ing.ingdirect.es` only —
never installed globally — so an SCA failure can't poison
subsequent calls.

## Response envelope (`/search`)

```json
{
  "transactions": [ ... ],
  "limit": 100,
  "offset": 0,
  "count": <N>,
  "total": <N>,
  "moreSca": false,
  "mayHasMoreElements": false,
  "mode": "P"
}
```

- `count` / `total`: pagination metadata.
- `moreSca: true`: response was truncated due to insufficient LoA;
  needs SCA elevation to see the full window.
- `mayHasMoreElements`: not authoritative for pagination — the
  framework terminates on `batch.size < limit` instead.
- `mode`: echoes the search scope ("P" = pending statement
  scope). Don't infer per-row lifecycle from this field; it's the
  search mode, not a row attribute.

## Per-row shape (`/search`, detailed format)

```json
{
  "transactionId": { "productId": "<uuid>", "transactionSequence": <int> },
  "transactionDate": "YYYY-MM-DD",
  "description": "...",          // raw padded merchant string
  "subcategoryId": "<int>",      // ING category, orthogonal to direction
  "amount": "-NN.NN",            // STRING, signed
  "transactionCode": "<code>",   // RECIBSEPA, TFRINSPA, TCTPV, TCCR, INTFROUTX, etc.
  "concept": "...",              // asset rows only; CC rows omit
  "balance": <numeric>,
  "transactionLocalUUID": "___V1ID___...___V1ID___",
  "mode": "P"
}
```

Notable: `amount` is a **String**. `coerce_amount` in
`extractor.rb` uses `Float()` (strict — raises on garbage rather
than silently returning 0.0).

CC rows omit `concept`; asset rows include it. The normalizer
joins `description` and `concept` (when present) with `—` as a
sub-line separator for asset rows.

## Diagnostic patterns

When `/search` returns 0 rows or wrong-format rows, the four
silent-failure modes above all present identically. Walk them in
this order:

1. **CSRF**: check `derived_credentials.xsrf_token` resolves to
   a non-empty value (the extractor's startup check surfaces this).
2. **Content-Type**: confirm `define_post(json:)` is sending bare
   `application/json` (requires `freentonic` ≥ v0.10.1).
3. **Investment exclusion**: confirm the `uuids` array sent to
   `/search` doesn't include the investment UUID.
4. **Per-UUID isolation**: confirm each `/search` call carries a
   single-element `uuids` array.

The fastest discriminator is a manual `curl` matching the bridge's
exact captured Bearer + ESC + cookie and varying one parameter at
a time. Asset rows surviving correctly while CC rows go wrong is a
strong tell for (4); zero rows everywhere is more often (1) or (2).

## Test invariants worth knowing about

- `test_v2_search_per_uuid_keeps_rows_isolated_per_product`: pins
  the per-UUID call shape. Reverting to multi-UUID batching fails
  this test immediately.
- `test_short_lookback_uses_search_without_sca`: asserts N products
  produce N `/search` calls. Same regression pin.
- `test_v2_search_signed_amounts_round_trip_to_numeric`: pins that
  signed String amounts coerce to signed Numerics through to the
  normalizer.
- `test_investment_products_excluded_from_search_batch`: pins that
  `kind == "investment"` never appears in any `/search` call.
- `test_v2_search_missing_transaction_id_emits_nil_uuid`: pins the
  lose-a-row contract — malformed rows reach movements with
  `uuid: nil` and the normalizer drops them downstream.

# frozen_string_literal: true

# ING extractor — pure fetch orchestration.
#
# All products go through a single unified v2 endpoint on
# api.ing.ingdirect.es: POST /v2/products/transactions/search. Both
# asset and credit-card UUIDs can be fetched in one batched call
# (uuids: [...] array in the JSON body), windowed by a date range
# (fromDate/toDate), and the response returns rows tagged with
# `transactionId.productId` so we demultiplex back to individual
# products. The stable id everywhere is
# `v2-seq:<productId>:<transactionSequence>`.
#
# The legacy `/genoma_api/rest/products/{v1id}/movements` endpoint and
# its `___V1ID___…___V1ID___` opaque envelope ids are gone — that
# envelope was a per-request encrypted blob, NOT a stable id, and
# refetches drifted the id across pending → cleared description
# enrichment, producing duplicate canonical rows downstream. The
# per-product /v2/products/{uuid}/transactions and credit-card-only
# /v2/products/credit-cards/{uuid}/extract endpoints have also been
# retired in favor of /search:
#  - /search returns historical (older than current statement) CC rows
#    that /extract's mode=P window could not reach.
#  - /search re-surfaces rows that have transitioned out of pending,
#    which mode=P could not (a row clearing at the bank disappeared
#    from mode=P forever, leaving the canonical row stuck `pending`).
#
# Trade-offs accepted:
#  - /search omits the CC `status` hash, so credit-card rows normalize
#    as `settled` regardless of lifecycle stage. Cosmetic for our
#    downstream consumers; the canonical-id stability fix is what
#    mattered. If a future consumer needs pending-status fidelity, the
#    fix is to layer a per-CC /extract?mode=P overlay on top of the
#    /search results, merging by transactionSequence.
#  - /search emits `amount` as a String (e.g. "-151.70"). Rows are
#    attached to products verbatim; all shape translation (String →
#    Numeric amount, ISO → DD/MM/YYYY dates, v2-seq stable-id
#    synthesis) lives in the normalizer.
#
# SCA elevation is NOT this extractor's job anymore. When the requested
# lookback crosses ING's 90-day boundary (/search rejects older ranges
# from a low-LoA Bearer as `moreSca: true`, silently truncating at the
# boundary), the workflow's declarative `elevate:` phase runs the PSD2
# handshake BEFORE extract — push approval on the operator's phone,
# then a Bearer refresh rebound host-scoped onto the shared client (see
# workflow.yml). On elevation failure the framework degrades: extract
# runs with the captured low-LoA Bearer and history truncates at ~90d.
# This extractor never mutates the session — it runs with whatever
# Bearer the client carries.
#
# Bearer + X-ING-ExtendedSessionContext are JS-computed values the
# bank's frontend puts on its outbound /position-keeping call, captured
# by the workflow's capture_outbound_request_headers step and threaded
# per-request to api.ing.ingdirect.es via the host-scoped auth_headers
# block. A /position-keeping failure aborts the run (no product list,
# nothing to extract); operator-facing error messages point at re-auth
# in the cases that aren't recoverable mid-run.

require "freentonic"

module Freentonic
  module Providers
    module Ing
      class Extractor < Freentonic::Providers::ExtractorBase
        provider!(__dir__)
        # KIND_BY_PRODUCT_TYPE auto-defined from ing/config.yml.

        def call(client:, credentials:, from_date:, stdout:, stderr:)
          api_headers = credentials[:ing_api_headers].is_a?(Hash) ? credentials[:ing_api_headers] : {}
          unless api_headers["Authorization"].to_s.length.positive?
            raise Freentonic::UserError,
                  "ING extract: ing_api_headers.Authorization not captured. The v2 " \
                  "endpoint requires the JS-computed Bearer the bank's frontend emits " \
                  "on /position-keeping; the workflow's capture_outbound_request_headers " \
                  "step must complete during post_login. Re-run after a fresh login."
          end

          # CSRF preflight. /search is a POST and ING silently returns
          # an empty `transactions` array when X-XSRF-TOKEN is absent.
          # The framework's host-scoped auth_headers block reads the
          # token from the cookie via a derived_credential — but only
          # if the XSRF-TOKEN cookie was actually captured at login
          # time. capture_cookie_header is host-scoped, so cookies
          # whose `domain` attribute is api.ing.ingdirect.es (not a
          # parent like .ingdirect.es or ing.ingdirect.es) get dropped
          # from the capture. Surface the state explicitly here so the
          # symptom (zero transactions across all products) is
          # diagnosable from the run log alone.
          cookie = credentials[:cookie].to_s
          xsrf_match = cookie.match(/XSRF-TOKEN=([^;]+)/)
          if xsrf_match.nil? || xsrf_match[1].to_s.empty?
            stderr.puts "  ⚠ XSRF-TOKEN cookie NOT present in captured Cookie header. " \
                        "/search POST will return empty `transactions` (ING silently " \
                        "rejects state-changing requests missing CSRF). The XSRF-TOKEN " \
                        "cookie may be scoped to api.ing.ingdirect.es rather than " \
                        "ing.ingdirect.es — capture_cookie_header would skip it. Run " \
                        "may complete with 0 rows."
          else
            stdout.puts "  XSRF-TOKEN cookie present (#{xsrf_match[1].length} chars)."
          end

          lookback_days = (Date.today - from_date).to_i
          stdout.puts "  /search path (lookback=#{lookback_days}d)."
          run_v2_path(client, from_date, stdout, stderr)
        end

        private

        # ---------------------------------------------------------------
        # /search path. The Bearer + ExtendedSessionContext are wired up
        # declaratively via the api_client's host-scoped auth_headers
        # block; if the elevate: phase ran, the client already carries
        # the rebound high-LoA Bearer. /position-keeping failure is the
        # only unrecoverable case (no product list).
        # ---------------------------------------------------------------

        def run_v2_path(client, from_date, stdout, stderr)
          # /position-keeping is the source of the product list. Failure
          # here means we cannot enumerate any accounts — letting the run
          # continue would emit a successful 0-account payload that
          # downstream stores would treat as "all accounts deleted",
          # overwriting real history. Hard-abort instead.
          position = fetch_position_keeping(client, stdout, stderr)

          uuid_map = build_uuid_map(position["products"])
          products = Array(position["legacyProducts"])
          stdout.puts "  Products found: #{products.size} (via /position-keeping)"

          # Partition products into ones we can fetch (have a v2 UUID
          # AND a kind /search accepts) and ones we have to skip.
          # Skipping is loud — without a stable v2 UUID we have no
          # stable id path; falling back to the retired legacy
          # /movements endpoint would silently re-introduce the dup
          # class (see top-of-file comment).
          #
          # Investment products (kind=investment, ING type 42 "Cuenta
          # de valores") are silently rejected by /search with HTTP
          # 401 even on a fresh low-LoA Bearer — and crucially, when
          # included in a multi-UUID batch they poison the entire
          # call (the batch returns 401, not just the investment
          # row). Exclude them upfront so the batch covers only
          # /search-compatible products. Their account entry still
          # gets emitted by the normalizer with the balance from
          # /position-keeping; just no transactions.
          fetchable = []
          products.each do |product|
            next unless processable?(product, stdout)
            v2_uuid = uuid_map[product["uuid"]]
            product["movements"] = []   # default; overwritten below if rows arrive
            kind = KIND_BY_PRODUCT_TYPE[product["type"].to_i]
            if v2_uuid.nil?
              stderr.puts "  ⚠ No v2 UUID for #{first_present(product['alias'], product['name'])} " \
                          "(kind=#{kind}, local=#{product['uuid']}) — skipping extraction."
              next
            end
            if kind == "investment"
              stdout.puts "  Skipping #{first_present(product['alias'], product['name'])} " \
                          "(kind=investment): /search returns 401 for investment UUIDs " \
                          "and poisons multi-UUID batches."
              next
            end
            if kind == "loan"
              stdout.puts "  Serving #{first_present(product['alias'], product['name'])} " \
                          "balance-only (kind=loan): amortization isn't in /search; " \
                          "payments post on the linked account."
              next
            end
            fetchable << [product, v2_uuid]
          end

          if fetchable.any?
            fetch_v2_search_into_products(fetchable, client, from_date, stdout, stderr)
          end

          products
        end

        # Fatal — raises Freentonic::UserError on any failure so the run
        # aborts cleanly with an actionable message. Never returns nil:
        # callers can rely on getting a well-shaped Hash back.
        def fetch_position_keeping(client, stdout, _stderr)
          stdout.puts "  Fetching /position-keeping for V1ID→UUID mapping..."
          resp = client.fetch_position_keeping
          unless resp.is_a?(Hash) && resp["legacyProducts"].is_a?(Array)
            raise Freentonic::UserError,
                  "ING extract: /position-keeping returned no legacyProducts array. " \
                  "Without it the product list is unknown and the run cannot continue. " \
                  "Re-run after a fresh login."
          end
          resp
        rescue Freentonic::UserError
          raise
        rescue StandardError => e
          raise Freentonic::UserError,
                "ING extract: /position-keeping failed (#{e.class}: #{e.message}). " \
                "Without the product list the run cannot continue. Re-run after a " \
                "fresh login; if the failure persists, the captured Bearer / " \
                "ExtendedSessionContext may be stale."
        end

        # Walk position-keeping's modern products array, building
        # V1ID(LOCAL_UUID) → raw UUID. Skips products without a populated
        # UUID. Both asset and credit-card products are expected to
        # carry a UUID-typed identifier in /position-keeping; any
        # product missing one will fall through to the "no v2 UUID"
        # branch in run_v2_path and be skipped with an operator-facing
        # warning rather than silently re-routed to the retired legacy
        # /movements endpoint.
        def build_uuid_map(modern_products)
          map = {}
          Array(modern_products).each do |p|
            ids = Array(p["identifiers"])
            local = ids.find { |i| i["type"] == "LOCAL_UUID" }&.dig("value")
            uuid  = ids.find { |i| i["type"] == "UUID" }&.dig("value")
            map[local] = uuid if local && uuid && !uuid.to_s.empty?
          end
          map
        end

        # ---------------------------------------------------------------
        # /search fetch — ONE CALL PER PRODUCT UUID.
        #
        # ING's /v2/products/transactions/search has an undocumented
        # quirk: passing multiple UUIDs in the `uuids` array triggers
        # a "summary" response format that strips signs from
        # credit-card amounts and humanizes descriptions ("Pago en X",
        # "Abonos Varios X"). Passing a single-element `uuids` array
        # triggers the "detailed" format that matches the bank's XLS
        # export — signed amounts, raw padded merchant descriptions,
        # everything we need verbatim.
        #
        # Verified live 2026-05-22: identical date window, same
        # captured Bearer + ESC + cookie, single-UUID body returns
        # `"amount":"-1331.47"` where multi-UUID body returns
        # `"amount":"1331.47"`. Same seq, same row, two response
        # shapes. The choice is per-product calls — a small handful
        # of extra HTTP requests per sync, but the data lands
        # canonical and the sign-flip heuristic disappears entirely.
        #
        # Each call goes through the declarative fetch_v2_search
        # endpoint (json: body, paginated by offset). Rows from one
        # call already belong to one product, so no demux is needed —
        # they attach VERBATIM to that product's movements. All shape
        # translation (String amounts, ISO dates, v2-seq stable-id
        # synthesis) lives in the normalizer — the raw payload carries
        # honest /search rows.
        # ---------------------------------------------------------------

        def fetch_v2_search_into_products(fetchable, client, from_date, stdout, stderr)
          stdout.puts "  Fetching /search for #{fetchable.size} product(s) (one call each)..."
          fetchable.each_with_index do |(product, v2_uuid), i|
            name = first_present(product["alias"], product["name"])
            rows = safe_fetch(stderr, "v2 search (#{name})") {
              client.fetch_v2_search(
                uuids:     [v2_uuid],
                from_date: from_date,
                to_date:   Date.today
              )
            } || []
            product["movements"] = Array(rows)
            stdout.puts "    [#{i + 1}/#{fetchable.size}] #{name}: #{product['movements'].size} rows"
          end
        end

        # ---------------------------------------------------------------
        # Shared utilities.
        # ---------------------------------------------------------------

        def processable?(product, stdout)
          type_id = product["type"].to_i
          if KIND_BY_PRODUCT_TYPE[type_id].nil?
            stdout.puts "  Skipping product type #{type_id} (#{first_present(product['alias'], product['name'])})"
            return false
          end
          true
        end
      end
    end
  end
end

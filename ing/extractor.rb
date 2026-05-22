# frozen_string_literal: true

# ING extractor.
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
#  - /search emits `amount` as a String (e.g. "-151.70"). Coerced to
#    Numeric in coerce_v2_search_to_legacy_shape.
#
# Routing matrix:
#
#   Bearer captured?  Lookback > 90d?  Prompt store?  → Behavior
#   ─────────────────────────────────────────────────────────────────
#   yes               no               (don't care)   → /search, no SCA
#   yes               yes              yes            → /search, with SCA
#   yes               yes              no             → /search, no SCA + truncation warning
#   no                (don't care)     (don't care)   → empty run, re-auth required
#
# Bearer + X-ING-ExtendedSessionContext are JS-computed values the
# bank's frontend puts on its outbound /position-keeping call, captured
# by the workflow's capture_outbound_request_headers step. Auth is
# always passed per-request to api.ing.ingdirect.es — never installed
# globally — so an SCA failure can't poison subsequent calls. SCA
# elevation (PSD2 push approval on operator's phone + Bearer refresh
# via /saf/tpa/accesstoken/synchronize) is only attempted when
# lookback > 90d, because that's the threshold above which /search
# rejects requests as `moreSca: true` without an elevated
# level-of-assurance. Short-lookback /search calls use the captured
# (low-LoA) Bearer directly.
#
# Failures inside the /search path degrade in place rather than
# switching id scheme: SCA timeout / Bearer refresh failure continue
# with the captured non-elevated Bearer (history truncated at ~90d);
# a /position-keeping failure aborts the run (no product list, nothing
# to extract). Operator-facing error messages point at re-auth in the
# cases that aren't recoverable mid-run.

require "freentonic"

module Freentonic
  module Providers
    module Ing
      class Extractor < Freentonic::Providers::ExtractorBase
        provider!(__dir__)
        # KIND_BY_PRODUCT_TYPE auto-defined from ing/config.yml.

        # Lookback threshold above which we run SCA elevation. ING's
        # /v2/products/transactions/search refuses date ranges older
        # than 90 days from a low-LoA Bearer (signaled by
        # `moreSca: true` in the response envelope; the server
        # truncates the response at the 90d boundary). Threshold sits
        # exactly at 90 so a 90d-lookback run still goes through
        # without SCA — the elevation only fires when the operator
        # actually wants history older than the silent cap.
        SCA_ELEVATION_LOOKBACK_DAYS = 90

        # Operator gets ~3 minutes to find their phone and approve.
        SCA_PROMPT_TIMEOUT_SECONDS = 180

        # The genoma_api SCA endpoints are still called via raw_request
        # (the GET → operator prompt → PUT handshake is genuinely
        # imperative), so we keep the legacy host URL handy.
        ING_LEGACY_HOST  = "https://ing.ingdirect.es"
        # Hostname (no scheme) used to scope update_auth_headers! to the
        # api host after SCA mints a new Bearer.
        ING_API_HOSTNAME = "api.ing.ingdirect.es"

        def call(client:, credentials:, from_date:, stdout:, stderr:,
                 remote_prompt_store: nil, run_dir: nil)
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
          perform_sca   = lookback_days > SCA_ELEVATION_LOOKBACK_DAYS && !remote_prompt_store.nil?
          if lookback_days > SCA_ELEVATION_LOOKBACK_DAYS && remote_prompt_store.nil?
            stderr.puts "  ⚠ Lookback #{lookback_days}d > #{SCA_ELEVATION_LOOKBACK_DAYS} but " \
                        "no operator prompt store available; running /search without " \
                        "elevation (history will be truncated at ING's #{SCA_ELEVATION_LOOKBACK_DAYS}-day silent boundary)."
          end

          stdout.puts "  /search path (lookback=#{lookback_days}d, sca=#{perform_sca})."
          run_v2_path(client, from_date, stdout, stderr,
                      remote_prompt_store, perform_sca: perform_sca)
        end

        private

        # ---------------------------------------------------------------
        # /search path. `perform_sca:` toggles the PSD2 elevation
        # handshake. The Bearer + ExtendedSessionContext are wired up
        # declaratively via the api_client's host-scoped auth_headers
        # block — when SCA produces a fresh high-LoA Bearer we rotate
        # it onto the client with
        # `update_auth_headers!(host: "api.ing.ingdirect.es")` so the
        # new value reaches the api host and ONLY the api host (the
        # legacy host stays cookie-only for the SCA documentation
        # handshake itself).
        #
        # Internal failures degrade in place — SCA timeout / Bearer
        # refresh failure continue with the captured (low-LoA) Bearer
        # and accept the ~90-day truncation. /position-keeping failure
        # is the only unrecoverable case (no product list).
        # ---------------------------------------------------------------

        def run_v2_path(client, from_date, stdout, stderr, prompt_store, perform_sca:)
          # /position-keeping is the source of the product list. Failure
          # here means we cannot enumerate any accounts — letting the run
          # continue would emit a successful 0-account payload that
          # downstream stores would treat as "all accounts deleted",
          # overwriting real history. Hard-abort instead.
          position = fetch_position_keeping(client, stdout, stderr)

          if perform_sca
            if attempt_sca_elevation(client, prompt_store, stdout, stderr)
              new_bearer = refresh_bearer_after_sca(client, stdout, stderr)
              if new_bearer
                client.update_auth_headers!({ "Authorization" => "Bearer #{new_bearer}" },
                                            host: ING_API_HOSTNAME)
              else
                stderr.puts "    ⚠ Bearer refresh failed; continuing with captured Bearer (history truncated at ~90d)."
              end
            else
              stderr.puts "    ⚠ SCA elevation failed; continuing with captured Bearer (history truncated at ~90d)."
            end
          end

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

        def refresh_bearer_after_sca(client, stdout, stderr)
          stdout.puts "  Refreshing Bearer after SCA elevation..."
          resp = client.refresh_access_token
          token = resp.dig("accessTokens", 0, "accessToken")
          if token.to_s.empty?
            stderr.puts "    ✗ Bearer refresh: response missing accessTokens[0].accessToken"
            return nil
          end
          token
        rescue StandardError => e
          stderr.puts "    ✗ Bearer refresh failed: #{e.class}: #{e.message}"
          nil
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

        # Initiate the SCA challenge, prompt the operator, commit on
        # approval. Cookie + bearer auth on the genoma host.
        def attempt_sca_elevation(client, prompt_store, stdout, stderr)
          doc = client.raw_request(
            method:  :get,
            path:    "/genoma_api/rest/sca/documentation",
            headers: { "x-ing-reset-validations" => "1" },
            base:    ING_LEGACY_HOST
          )

          acceptance = Array(doc["acceptanceMethods"]).first
          unless acceptance
            stderr.puts "    ✗ SCA elevation: no acceptanceMethods in /sca/documentation response"
            return false
          end

          process_id = acceptance["securityProcessId"].to_s
          if process_id.empty?
            stderr.puts "    ✗ SCA elevation: no securityProcessId in /sca/documentation response"
            return false
          end

          stdout.puts "  Awaiting operator approval (push notification on phone)..."
          begin
            prompt_store.prompt(
              kind:            :confirm,
              message:         sca_prompt_message(acceptance),
              timeout_seconds: SCA_PROMPT_TIMEOUT_SECONDS
            )
          rescue Freentonic::RemotePromptStore::Timeout
            stderr.puts "    ✗ SCA elevation: operator did not approve within " \
                        "#{SCA_PROMPT_TIMEOUT_SECONDS}s"
            return false
          end

          client.raw_request(
            method:  :put,
            path:    "/genoma_api/rest/sca/documentation",
            headers: { "x-ing-securityprocessid" => process_id },
            body:    { "processId" => process_id },
            base:    ING_LEGACY_HOST
          )

          stdout.puts "    ✓ SCA elevation succeeded"
          true
        rescue StandardError => e
          stderr.puts "    ✗ SCA elevation failed: #{e.class}: #{e.message}"
          false
        end

        def sca_prompt_message(acceptance)
          base = "ING is requesting Strong Customer Authentication to release " \
                 "older transaction history. Open the ING app on your phone, " \
                 "tap the pending notification, and approve. The sync will " \
                 "automatically resume once approved."
          code = acceptance["code"]
          return base unless code
          "#{base} (challenge: #{code})"
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
        # they assign directly to that product's movements.
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
            product["movements"] = Array(rows).map { |r| coerce_v2_search_to_legacy_shape(r) }
            stdout.puts "    [#{i + 1}/#{fetchable.size}] #{name}: #{product['movements'].size} rows"
          end
        end

        # Translate a /search row to the legacy /movements shape the
        # normalizer consumes. /search's envelope is a subset of the
        # previous per-product v2 endpoints — most notably it omits
        # the CC `status` hash (so CC rows lose pending/settled
        # distinction and normalize as `settled`) and exposes `amount`
        # as a String (e.g. "-151.70") rather than a Numeric.
        #
        # The emitted `uuid` is the per-ledger-position cursor
        # `v2-seq:<productId>:<transactionSequence>`. That cursor is
        # ING's stable identity for the row across requests; the
        # `transactionLocalUUID` field is an opaque envelope encrypted
        # with a per-request nonce, so different fetches of the same
        # row see different `transactionLocalUUID` values. We never
        # use it as the canonical id source.
        def coerce_v2_search_to_legacy_shape(tx)
          {
            "uuid"          => v2_stable_uuid(tx),
            "amount"        => coerce_amount(tx["amount"]),
            "effectiveDate" => yyyy_mm_dd_to_dd_mm_yyyy(tx["transactionDate"]),
            "description"   => tx["description"],
            "currency"      => "EUR",
            "tranCode"      => tx["transactionCode"],
            "store"         => tx["concept"],
            "_v2_source"               => true,
            "_v2_kind"                 => "search",
            "_v2_subcategoryId"        => tx["subcategoryId"],
            "_v2_balance"              => tx["balance"],
            "_v2_transactionSequence"  => tx.dig("transactionId", "transactionSequence"),
            "_v2_transactionLocalUUID" => tx["transactionLocalUUID"],
            "_v2_mode"                 => tx["mode"]
          }
        end

        # /search returns amount as a String ("-151.70"). The
        # normalizer requires a Numeric (returns nil for non-Numeric
        # amounts to drop the row). Float() parses strictly — raising
        # on garbage rather than silently coercing to 0.0 — so a
        # malformed amount becomes a visible error rather than a
        # silently-dropped row that would mask data quality issues.
        # Numeric values pass through unchanged for forward-compat in
        # case ING flips this back to a Numeric.
        def coerce_amount(raw)
          case raw
          when Numeric then raw
          when String  then Float(raw)
          else nil
          end
        rescue ArgumentError
          nil
        end

        # Per-product, per-position stable id. Returns nil if the v2
        # response omits `transactionId`; the normalizer treats nil
        # uuid as "drop this transaction" rather than synthesise an
        # unstable fallback — we'd rather lose a row than re-introduce
        # the dup bug.
        def v2_stable_uuid(tx)
          product_id = tx.dig("transactionId", "productId").to_s
          seq        = tx.dig("transactionId", "transactionSequence").to_s
          return nil if product_id.empty? || seq.empty?
          "v2-seq:#{product_id}:#{seq}"
        end

        def yyyy_mm_dd_to_dd_mm_yyyy(s)
          return nil unless s.is_a?(String) && s =~ /\A\d{4}-\d{2}-\d{2}\z/
          y, m, d = s.split("-")
          "#{d}/#{m}/#{y}"
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

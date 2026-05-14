# frozen_string_literal: true

# ING extractor.
#
# Asset products always go through the v2 path. The legacy
# `/genoma_api/rest/products/{v1id}/movements` endpoint is NOT a
# fallback for assets — its `___V1ID___…___V1ID___` id envelope is
# stable within itself but inter-incompatible with the v2 path's
# `v2-seq:<productId>:<transactionSequence>` scheme, and a single
# canonical profile that flips between them emits two `txn_<hex>` for
# the same ledger row (the r3 dup bug). The cure is to never run
# the legacy path on assets, so the v1 orchestration is gone entirely.
#
# Credit cards still hit `legacy_fetch_all_movements` because ING's
# /position-keeping doesn't carry a v2 UUID for them and the bank's
# own SPA dispatches them the same way — that's a card-specific API
# constraint, not legacy-era extraction code.
#
# Routing matrix:
#
#   Bearer captured?  Lookback > 60d?  Prompt store?  → Behavior
#   ─────────────────────────────────────────────────────────────────
#   yes               no               (don't care)   → v2, no SCA
#   yes               yes              yes            → v2, with SCA
#   yes               yes              no             → v2, no SCA + truncation warning
#   no                (don't care)     (don't care)   → empty run, re-auth required
#
# Bearer + X-ING-ExtendedSessionContext are JS-computed values the
# bank's frontend put on its outbound /position-keeping call, captured
# by the workflow's capture_outbound_request_headers step. Auth is
# always passed per-request to api.ing.ingdirect.es — never installed
# globally — so an SCA failure can't poison subsequent calls. SCA
# elevation (PSD2 push approval on operator's phone + Bearer refresh
# via /saf/tpa/accesstoken/synchronize) is only attempted when
# lookback > 60d, because that's the threshold above which ING's v2
# /transactions endpoint silently truncates without an elevated
# level-of-assurance. Short-lookback v2 calls use the captured
# (low-LoA) Bearer directly.
#
# Failures inside the v2 path degrade in place rather than falling
# back to a different id scheme: SCA timeout / Bearer refresh failure
# continue with the captured non-elevated Bearer (truncated to ~52d);
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

        # Lookback threshold above which we run SCA elevation. ING's v2
        # /transactions endpoint silently caps at ~52 days without
        # elevation; 60 leaves a small buffer.
        SCA_ELEVATION_LOOKBACK_DAYS = 60

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

          lookback_days = (Date.today - from_date).to_i
          perform_sca   = lookback_days > SCA_ELEVATION_LOOKBACK_DAYS && !remote_prompt_store.nil?
          if lookback_days > SCA_ELEVATION_LOOKBACK_DAYS && remote_prompt_store.nil?
            stderr.puts "  ⚠ Lookback #{lookback_days}d > #{SCA_ELEVATION_LOOKBACK_DAYS} but " \
                        "no operator prompt store available; running v2 without elevation " \
                        "(asset history will be truncated at ING's ~52-day silent boundary)."
          end

          stdout.puts "  v2 path (lookback=#{lookback_days}d, sca=#{perform_sca})."
          run_v2_path(client, from_date, stdout, stderr,
                      remote_prompt_store, perform_sca: perform_sca)
        end

        private

        # ---------------------------------------------------------------
        # v2 path. `perform_sca:` toggles the PSD2 elevation handshake.
        # The Bearer + ExtendedSessionContext are wired up declaratively
        # via the api_client's host-scoped auth_headers block — when SCA
        # produces a fresh high-LoA Bearer we rotate it onto the client
        # with `update_auth_headers!(host: "api.ing.ingdirect.es")` so
        # the new value reaches the api host and ONLY the api host (the
        # legacy host's cards endpoint stays cookie-only).
        #
        # Internal failures degrade in place — SCA timeout / Bearer
        # refresh failure continue with the captured (low-LoA) Bearer
        # and accept the ~52-day truncation. /position-keeping failure
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
                stderr.puts "    ⚠ Bearer refresh failed; continuing with captured Bearer (asset history truncated at ~52d)."
              end
            else
              stderr.puts "    ⚠ SCA elevation failed; continuing with captured Bearer (asset history truncated at ~52d)."
            end
          end

          uuid_map = build_uuid_map(position["products"])
          products = Array(position["legacyProducts"])
          stdout.puts "  Products found: #{products.size} (via /position-keeping)"

          products.each do |product|
            next unless processable?(product, stdout)
            kind = KIND_BY_PRODUCT_TYPE[product["type"].to_i]
            v2_uuid = uuid_map[product["uuid"]]

            if kind == "asset" && v2_uuid
              fetch_v2_transactions_into(product, client, v2_uuid, from_date, stdout, stderr)
            else
              # Credit cards (no v2 UUID) — legacy endpoint, cookie auth
              # only. The host-scoped auth_headers block keeps the v2
              # Bearer off the legacy host so this call doesn't 401.
              fetch_card_movements_into(product, client, from_date, stdout, stderr)
            end
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
        # UUID (credit cards have LOCAL_UUID only).
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
        # /movements fetch — credit-card products only. ING's
        # /position-keeping doesn't expose a v2 UUID for cards and the
        # bank's own SPA dispatches them through this endpoint; that's
        # an API-shape constraint, not legacy-era extraction code. The
        # host-scoped auth_headers block in workflow.yml keeps the v2
        # Bearer off this request so the legacy host doesn't 401.
        # ---------------------------------------------------------------

        def fetch_card_movements_into(product, client, from_date, stdout, stderr)
          uuid = product["uuid"]
          kind = KIND_BY_PRODUCT_TYPE[product["type"].to_i]
          stdout.puts "  Fetching movements for #{first_present(product['alias'], product['name'])} (#{kind})..."
          product["movements"] = safe_fetch(stderr, "movements") {
            movements = client.legacy_fetch_all_movements(v1id: uuid, from_date: from_date)
            stdout.puts "    → #{movements.size} movements"
            movements
          } || []
        end

        # ---------------------------------------------------------------
        # v2 transactions fetch — delegates to the declared
        # fetch_v2_transactions endpoint, which paginates by offset
        # under the workflow's pagination machinery. Each page's rows
        # are coerced to legacy /movements shape so the normalizer
        # doesn't have to dispatch on which path produced them.
        # ---------------------------------------------------------------

        def fetch_v2_transactions_into(product, client, raw_uuid, from_date, stdout, stderr)
          stdout.puts "  Fetching transactions (v2) for #{first_present(product['alias'], product['name'])}..."
          transactions = safe_fetch(stderr, "v2 transactions") {
            client.fetch_v2_transactions(
              raw_uuid:  raw_uuid,
              from_date: from_date,
              to_date:   Date.today
            )
          } || []
          coerced = Array(transactions).map { |t| coerce_v2_transaction_to_legacy_shape(t) }
          stdout.puts "    → #{coerced.size} transactions"
          product["movements"] = coerced
        end

        # Translate v2 → legacy /movements field names so the normalizer
        # doesn't need to dispatch on shape. v2-only fields land under
        # _v2_* keys for downstream debugging.
        #
        # The emitted `uuid` is the per-ledger-position cursor
        # `v2-seq:<productId>:<transactionSequence>`. That cursor is
        # ING's stable identity for the row across requests; the
        # `transactionLocalUUID` field is an opaque envelope encrypted
        # with a per-request nonce, so different fetches of the same
        # row see different `transactionLocalUUID` values. We never
        # use it as the canonical id source.
        def coerce_v2_transaction_to_legacy_shape(tx)
          {
            "uuid"          => v2_stable_uuid(tx),
            "amount"        => tx["amount"],
            "effectiveDate" => yyyy_mm_dd_to_dd_mm_yyyy(tx["transactionDate"]),
            "description"   => tx["description"],
            "currency"      => "EUR",
            "tranCode"      => tx["transactionCode"],
            "store"         => tx["concept"],
            "_v2_source"              => true,
            "_v2_subcategoryId"       => tx["subcategoryId"],
            "_v2_issuerId"            => tx["issuerId"],
            "_v2_excludedAmount"      => tx["excludedAmount"],
            "_v2_balance"             => tx["balance"],
            "_v2_transactionSequence" => tx.dig("transactionId", "transactionSequence"),
            "_v2_transactionLocalUUID" => tx["transactionLocalUUID"]
          }
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

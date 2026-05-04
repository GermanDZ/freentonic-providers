# frozen_string_literal: true

# ING extractor.
#
# Two execution paths gated on lookback_days:
#
# - Lookback ≤ 60 days (routine syncs): legacy genoma_api endpoints with
#   cookie-only auth. No bearer, no SCA prompt — the operator gets recent
#   movements without ceremony.
#
# - Lookback > 60 days (deep syncs): elevated path. Mint a Bearer via
#   /genoma_api/saf/tpa/accesstoken, fetch /position-keeping for the
#   V1ID→raw-UUID mapping, run the PSD2 SCA handshake (operator approves a
#   push notification on their phone), refresh the Bearer via /saf/tpa/
#   accesstoken/synchronize to upgrade its level-of-assurance, then fetch
#   asset transactions via the v2 endpoint on api.ing.ingdirect.es with
#   the elevated Bearer. Credit-card products stay on the legacy endpoint
#   throughout — their /position-keeping entries don't carry the v2 UUID
#   anyway, and ING's own SPA does the same dispatch.
#
# Any failure in the elevated path (bearer mint, /position-keeping,
# operator rejecting the prompt, SCA HTTP error, missing v2 UUID) falls
# back cleanly to the legacy path with the existing partial-data
# breadcrumb stamped on the affected products. SCA never breaks the run.

require "freentonic"

module Freentonic
  module Providers
    module Ing
      class Extractor < Freentonic::Providers::ExtractorBase
        provider!(__dir__)
        # KIND_BY_PRODUCT_TYPE auto-defined from ing/config.yml.

        # Lookback threshold above which we proactively run the v2 +
        # SCA elevation path. ING's checking-account /transactions
        # endpoint silently caps at ~52 days without elevation; 60 leaves
        # a small buffer.
        SCA_ELEVATION_LOOKBACK_DAYS = 60

        # Partial-data heuristic — defense-in-depth for the legacy path
        # only. Suppresses false positives on young/dormant accounts.
        PARTIAL_DATA_MIN_MOVEMENTS = 10
        PARTIAL_DATA_GAP_DAYS      = 30

        # Operator gets ~3 minutes to find their phone and approve. The
        # whole sync should finish well within the 245s Bearer TTL, so
        # don't extend this further.
        SCA_PROMPT_TIMEOUT_SECONDS = 180

        # v2 transactions pagination — limit per page; offset advances by
        # the response's `count`.
        V2_PAGE_LIMIT = 100

        ING_API_HOST    = "https://api.ing.ingdirect.es"
        ING_LEGACY_HOST = "https://ing.ingdirect.es"

        def call(client:, credentials:, from_date:, stdout:, stderr:,
                 remote_prompt_store: nil, run_dir: nil)
          lookback_days = (Date.today - from_date).to_i
          want_elevation = lookback_days > SCA_ELEVATION_LOOKBACK_DAYS

          if want_elevation && remote_prompt_store
            stdout.puts "  Lookback #{lookback_days} days > #{SCA_ELEVATION_LOOKBACK_DAYS}; " \
                        "running elevated path."
            elevated = run_elevated_path(client, from_date, stdout, stderr, remote_prompt_store)
            return elevated if elevated
            stdout.puts "  Elevated path didn't complete; falling back to legacy fetch."
          elsif want_elevation
            stderr.puts "  ⚠ Lookback #{lookback_days} days > #{SCA_ELEVATION_LOOKBACK_DAYS} but " \
                        "no operator prompt store available; running legacy path. Older history " \
                        "for SCA-gated checking accounts will be truncated."
          end

          run_legacy_path(client, from_date, stdout, stderr,
                          flag_truncation: want_elevation)
        end

        private

        # ---------------------------------------------------------------
        # Legacy path — cookie-only auth, /genoma_api/rest/products/*/movements.
        # ---------------------------------------------------------------

        def run_legacy_path(client, from_date, stdout, stderr, flag_truncation:)
          products = client.fetch_products_legacy_shape
          stdout.puts "  Products found: #{products.size}"

          products.each do |product|
            next unless processable?(product, stdout)
            fetch_legacy_movements_into(product, client, from_date, stdout, stderr)
            flag_partial_data_if_truncated(product, from_date, stderr) if flag_truncation
          end

          products
        end

        # ---------------------------------------------------------------
        # Elevated path — Bearer + /position-keeping + SCA + v2 transactions.
        # Returns nil on any failure so the caller falls back to legacy.
        # ---------------------------------------------------------------

        def run_elevated_path(client, from_date, stdout, stderr, prompt_store)
          bearer = mint_initial_bearer(client, stdout, stderr)
          return nil unless bearer
          client.update_auth_headers!("Authorization" => "Bearer #{bearer}")

          position = fetch_position_keeping(client, stdout, stderr)
          return nil unless position

          return nil unless attempt_sca_elevation(client, prompt_store, stdout, stderr)

          new_bearer = refresh_bearer_after_sca(client, stdout, stderr)
          return nil unless new_bearer
          client.update_auth_headers!("Authorization" => "Bearer #{new_bearer}")

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
              # Credit cards (no v2 UUID) and any defensive fallback. The
              # legacy endpoint accepts the now-elevated session cookie
              # too; even if the bank doesn't apply elevation to legacy,
              # the cards aren't SCA-gated in the first place.
              fetch_legacy_movements_into(product, client, from_date, stdout, stderr)
            end
          end

          products
        end

        # ---------------------------------------------------------------
        # Bearer mint, position-keeping, SCA, refresh — each a small wrapper
        # around client.raw_request that returns nil on failure so the
        # outer pipeline can fall back gracefully.
        # ---------------------------------------------------------------

        def mint_initial_bearer(client, stdout, stderr)
          stdout.puts "  Minting initial Bearer..."
          resp = client.raw_request(
            method: :get,
            path:   "/genoma_api/saf/tpa/accesstoken",
            base:   ING_LEGACY_HOST
          )
          token = resp.dig("accessTokens", 0, "accessToken")
          if token.to_s.empty?
            stderr.puts "    ✗ Bearer mint: response missing accessTokens[0].accessToken"
            return nil
          end
          token
        rescue StandardError => e
          stderr.puts "    ✗ Bearer mint failed: #{e.class}: #{e.message}"
          nil
        end

        def fetch_position_keeping(client, stdout, stderr)
          stdout.puts "  Fetching /position-keeping for V1ID→UUID mapping..."
          resp = client.raw_request(
            method: :get,
            path:   "/position-keeping",
            base:   ING_API_HOST
          )
          unless resp.is_a?(Hash) && resp["legacyProducts"].is_a?(Array)
            stderr.puts "    ✗ /position-keeping: missing legacyProducts array"
            return nil
          end
          resp
        rescue StandardError => e
          stderr.puts "    ✗ /position-keeping failed: #{e.class}: #{e.message}"
          nil
        end

        def refresh_bearer_after_sca(client, stdout, stderr)
          stdout.puts "  Refreshing Bearer after SCA elevation..."
          resp = client.raw_request(
            method: :get,
            path:   "/saf/tpa/accesstoken/synchronize",
            base:   ING_API_HOST
          )
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

        # Same flow as before — request the SCA challenge, prompt the
        # operator, commit on approval. Cookie auth throughout (the SCA
        # endpoints live on the genoma host, not the api host).
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
                        "#{SCA_PROMPT_TIMEOUT_SECONDS}s; falling back to legacy"
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
        # Legacy /movements fetch — unchanged from pre-SCA behavior.
        # ---------------------------------------------------------------

        def fetch_legacy_movements_into(product, client, from_date, stdout, stderr)
          uuid = product["uuid"]
          kind = KIND_BY_PRODUCT_TYPE[product["type"].to_i]
          stdout.puts "  Fetching movements (legacy) for #{first_present(product['alias'], product['name'])} (#{kind})..."
          product["movements"] = safe_fetch(stderr, "movements") {
            movements = client.legacy_fetch_all_movements(v1id: uuid, from_date: from_date)
            stdout.puts "    → #{movements.size} movements"
            movements
          } || []
        end

        # ---------------------------------------------------------------
        # v2 transactions fetch — paginate via response.count, stop when
        # mayHasMoreElements is false or count is 0. Coerce each page's
        # transactions to legacy /movements shape so the normalizer
        # doesn't need to know which path produced them.
        # ---------------------------------------------------------------

        def fetch_v2_transactions_into(product, client, raw_uuid, from_date, stdout, stderr)
          stdout.puts "  Fetching transactions (v2) for #{first_present(product['alias'], product['name'])}..."
          all = []
          offset = 0
          to_date = Date.today
          loop do
            resp = safe_fetch(stderr, "v2 transactions") {
              client.raw_request(
                method: :get,
                path:   "/v2/products/#{raw_uuid}/transactions",
                base:   ING_API_HOST,
                params: {
                  limit:     V2_PAGE_LIMIT,
                  offset:    offset,
                  fromDate:  from_date.iso8601,
                  toDate:    to_date.iso8601,
                  filterEru: false
                }
              )
            }
            break unless resp.is_a?(Hash)
            page = Array(resp["transactions"])
            all.concat(page.map { |t| coerce_v2_transaction_to_legacy_shape(t) })
            count = resp["count"].to_i
            break if count == 0
            offset += count
            break unless resp["mayHasMoreElements"]
          end
          stdout.puts "    → #{all.size} transactions"
          product["movements"] = all
        end

        # v2 transactions arrive with field names that differ from the
        # legacy /movements shape the normalizer's RAW_FIELDS_MOVEMENT
        # config expects. Translate at the seam — keeping the normalizer
        # untouched — and stash v2-only fields under _v2_* so they're
        # discoverable in the canonical metadata if downstream tooling
        # ever wants them.
        def coerce_v2_transaction_to_legacy_shape(tx)
          {
            "uuid"          => tx["transactionLocalUUID"],
            "amount"        => tx["amount"],
            "effectiveDate" => yyyy_mm_dd_to_dd_mm_yyyy(tx["transactionDate"]),
            "description"   => tx["description"],
            "currency"      => "EUR", # ES ING is single-currency; v2 omits the field
            "tranCode"      => tx["transactionCode"],
            "store"         => tx["concept"],
            "_v2_source"            => true,
            "_v2_subcategoryId"     => tx["subcategoryId"],
            "_v2_issuerId"          => tx["issuerId"],
            "_v2_excludedAmount"    => tx["excludedAmount"],
            "_v2_balance"           => tx["balance"],
            "_v2_transactionSequence" => tx.dig("transactionId", "transactionSequence")
          }
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

        # Defense-in-depth: if the legacy path was taken (either lookback
        # ≤ threshold OR elevated path failed at some leg), and an asset
        # product still looks truncated, stamp a breadcrumb so downstream
        # tooling knows the run isn't complete history.
        def flag_partial_data_if_truncated(product, from_date, stderr)
          kind = KIND_BY_PRODUCT_TYPE[product["type"].to_i]
          return unless kind == "asset"
          movements = Array(product["movements"])
          return if movements.size < PARTIAL_DATA_MIN_MOVEMENTS

          earliest = movements.map { |mv| movement_date(mv) }.compact.min
          return unless earliest
          gap_days = (earliest - from_date).to_i
          return if gap_days <= PARTIAL_DATA_GAP_DAYS

          name = first_present(product["alias"], product["name"]) || "ING product"
          stderr.puts "    ⚠ partial-data suspected for #{name}: earliest movement " \
                      "#{earliest.iso8601}, requested from #{from_date.iso8601} " \
                      "(#{gap_days}-day gap). ING gates older checking-account " \
                      "history behind PSD2 SCA elevation."
          product["_partial_data_suspected"] = {
            "from_date_requested" => from_date.iso8601,
            "earliest_returned"   => earliest.iso8601,
            "gap_days"            => gap_days,
            "movement_count"      => movements.size,
            "reason"              => "sca_elevation_required_suspected"
          }
        end

        def movement_date(mv)
          parse_date(mv["effectiveDate"] || mv["chargeDate"],
                     preferred_formats: ING_DATE_FORMATS)
        end
      end
    end
  end
end

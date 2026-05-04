# frozen_string_literal: true

# ING extractor: fetches products (accounts + cards) via the legacy
# genoma_api endpoint, then per-product movements. The resulting raw
# payload is an Array of product hashes, each with a "movements" key
# holding the raw movement list returned by the API.
#
# When ING short-pages a checking-account's movements (PSD2 SCA-gated
# older history), and a remote_prompt_store is available, the extractor
# attempts a single SCA elevation handshake mid-extraction (operator
# approves a push notification on their mobile app) and re-fetches the
# truncated products. Without a prompt store (headless / scheduled
# runs), or on any SCA failure, the truncation is recorded as a
# breadcrumb on the product and surfaced to the canonical envelope so
# downstream tooling can flag the run.

require "freentonic"

module Freentonic
  module Providers
    module Ing
      class Extractor < Freentonic::Providers::ExtractorBase
        provider!(__dir__)
        # KIND_BY_PRODUCT_TYPE auto-defined from ing/config.yml.

        # An asset product is "probably truncated" when more than
        # PARTIAL_DATA_MIN_MOVEMENTS came back but the earliest of them
        # is more than PARTIAL_DATA_GAP_DAYS days later than from_date.
        # The count guard suppresses false positives on young or dormant
        # accounts where the gap is legitimate.
        PARTIAL_DATA_MIN_MOVEMENTS = 10
        PARTIAL_DATA_GAP_DAYS      = 30

        # SCA prompt timeout. Push approval typically takes <30s; 3min
        # gives the operator time to find their phone and unlock it.
        SCA_PROMPT_TIMEOUT_SECONDS = 180

        def call(client:, credentials:, from_date:, stdout:, stderr:,
                 remote_prompt_store: nil, run_dir: nil)
          products = client.fetch_products_legacy_shape
          stdout.puts "  Products found: #{products.size}"

          # First pass: fetch movements for every processable product.
          processable = products.select { |p| processable?(p, stdout) }
          processable.each { |product| fetch_movements_into(product, client, from_date, stdout, stderr) }

          # If any asset product looks truncated and we have a prompt
          # store wired up (i.e. running under simplefreen-invoke with an
          # operator watching), attempt SCA elevation once and re-fetch
          # the truncated ones. Headless runs and SCA failures fall
          # through to the partial-data breadcrumb path.
          truncated = processable.select { |p| partial_data_suspected?(p, from_date) }
          if truncated.any? && remote_prompt_store
            stdout.puts "  #{truncated.size} product(s) appear truncated; attempting SCA elevation..."
            if attempt_sca_elevation(client, remote_prompt_store, stdout, stderr)
              stdout.puts "  Re-fetching truncated product(s) with elevated session..."
              truncated.each { |product| fetch_movements_into(product, client, from_date, stdout, stderr) }
            end
          end

          # Final pass: stamp the breadcrumb on whatever still looks
          # truncated. Re-fetch after elevation may have closed the gap;
          # if not, downstream tooling should know.
          processable.each { |product| flag_partial_data_if_truncated(product, from_date, stderr) }

          products
        end

        private

        def processable?(product, stdout)
          type_id = product["type"].to_i
          if KIND_BY_PRODUCT_TYPE[type_id].nil?
            stdout.puts "  Skipping product type #{type_id} (#{first_present(product['alias'], product['name'])})"
            return false
          end
          true
        end

        def fetch_movements_into(product, client, from_date, stdout, stderr)
          uuid = product["uuid"]
          kind = KIND_BY_PRODUCT_TYPE[product["type"].to_i]
          stdout.puts "  Fetching movements for #{first_present(product['alias'], product['name'])} (#{kind})..."
          product["movements"] = safe_fetch(stderr, "movements") {
            movements = client.legacy_fetch_all_movements(v1id: uuid, from_date: from_date)
            stdout.puts "    → #{movements.size} movements"
            movements
          } || []
        end

        # Attempt a single SCA elevation. Returns true on success, false
        # on any failure mode — the caller falls through to truncated-
        # data behavior. Never raises: an SCA glitch must not break the
        # rest of the run.
        def attempt_sca_elevation(client, prompt_store, stdout, stderr)
          doc = client.raw_request(
            method:  :get,
            path:    "/genoma_api/rest/sca/documentation",
            headers: { "x-ing-reset-validations" => "1" }
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
                        "#{SCA_PROMPT_TIMEOUT_SECONDS}s; continuing with truncated data"
            return false
          end

          client.raw_request(
            method:  :put,
            path:    "/genoma_api/rest/sca/documentation",
            headers: { "x-ing-securityprocessid" => process_id },
            body:    { "processId" => process_id }
          )

          stdout.puts "    ✓ SCA elevation succeeded"
          true
        rescue StandardError => e
          stderr.puts "    ✗ SCA elevation failed: #{e.class}: #{e.message}; " \
                      "continuing with truncated data"
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

        def partial_data_suspected?(product, from_date)
          kind = KIND_BY_PRODUCT_TYPE[product["type"].to_i]
          return false unless kind == "asset"
          movements = Array(product["movements"])
          return false if movements.size < PARTIAL_DATA_MIN_MOVEMENTS
          earliest = movements.map { |mv| movement_date(mv) }.compact.min
          return false unless earliest
          (earliest - from_date).to_i > PARTIAL_DATA_GAP_DAYS
        end

        def flag_partial_data_if_truncated(product, from_date, stderr)
          return unless partial_data_suspected?(product, from_date)
          # If a previous run of flag_… already stamped the same
          # breadcrumb (re-fetch did not close the gap), don't double-log
          # the warning to stderr. The breadcrumb itself stays.
          movements = Array(product["movements"])
          earliest = movements.map { |mv| movement_date(mv) }.compact.min
          gap_days = (earliest - from_date).to_i
          previous = product["_partial_data_suspected"]

          name = first_present(product["alias"], product["name"]) || "ING product"
          unless previous && previous["earliest_returned"] == earliest.iso8601
            stderr.puts "    ⚠ partial-data suspected for #{name}: earliest movement " \
                        "#{earliest.iso8601}, requested from #{from_date.iso8601} " \
                        "(#{gap_days}-day gap). ING gates older checking-account " \
                        "history behind PSD2 SCA elevation."
          end
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

# frozen_string_literal: true

# ING extractor: fetches products (accounts + cards) via the legacy
# genoma_api endpoint, then per-product movements. The resulting raw
# payload is an Array of product hashes, each with a "movements" key
# holding the raw movement list returned by the API.
#
# Extracted from scripts/lib/push_data/sources/ing.rb#fetch_payload.

require "freentonic"

module Freentonic
  module Providers
    module Ing
      class Extractor < Freentonic::Providers::ExtractorBase
        provider!(__dir__)
        # KIND_BY_PRODUCT_TYPE auto-defined from ing/config.yml.

        # If an asset product returns more than this many movements but the
        # earliest of them is more than this many days later than from_date,
        # treat the result as "probably truncated by SCA gating" and stash a
        # breadcrumb on the product. ING's web UI requires a fresh PSD2 SCA
        # elevation (mobile-app push approval) to release older history on
        # checking-account products; without it the legacy /movements
        # endpoint silently short-pages. The numeric guard avoids
        # false-positives on young or dormant accounts where the gap is
        # legitimate. Tunable per provider if other Spanish banks turn out
        # to behave the same.
        PARTIAL_DATA_MIN_MOVEMENTS = 10
        PARTIAL_DATA_GAP_DAYS      = 30

        def call(client:, credentials:, from_date:, stdout:, stderr:)
          products = client.fetch_products_legacy_shape
          stdout.puts "  Products found: #{products.size}"

          products.each do |product|
            type_id = product["type"].to_i
            kind = KIND_BY_PRODUCT_TYPE[type_id]
            if kind.nil?
              stdout.puts "  Skipping product type #{type_id} (#{first_present(product['alias'], product['name'])})"
              next
            end

            uuid = product["uuid"]
            stdout.puts "  Fetching movements for #{first_present(product['alias'], product['name'])} (#{kind})..."
            product["movements"] = safe_fetch(stderr, "movements") {
              movements = client.legacy_fetch_all_movements(v1id: uuid, from_date: from_date)
              stdout.puts "    → #{movements.size} movements"
              movements
            } || []

            flag_partial_data_if_truncated(product, kind, from_date, stderr)
          end

          products
        end

        private

        def flag_partial_data_if_truncated(product, kind, from_date, stderr)
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

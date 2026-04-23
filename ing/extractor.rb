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
          end

          products
        end
      end
    end
  end
end

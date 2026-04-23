# frozen_string_literal: true

# ING extractor: fetches products (accounts + cards) via the legacy
# genoma_api endpoint, then per-product movements. The resulting raw
# payload is an Array of product hashes, each with a "movements" key
# holding the raw movement list returned by the API.
#
# Extracted from scripts/lib/push_data/sources/ing.rb#fetch_payload.

require "freentonic"
Freentonic::Providers::Config.load_provider!(__dir__)

module Freentonic
  module Providers
    module Ing
      class Extractor
        # Numeric ING product type → canonical kind. Sourced from
        # ing/config.yml so a per-provider PR that adjusts the mapping
        # is a YAML diff rather than a Ruby diff. The Extractor still
        # references it via this constant so it can log which products
        # were skipped and why.
        KIND_BY_PRODUCT_TYPE = Freentonic::Providers::Config.for(:ing).fetch(:kind_by_product_type).freeze

        def call(client:, credentials:, from_date:, stdout:, stderr:)
          products = client.fetch_products_legacy_shape
          stdout.puts "  Products found: #{products.size}"

          products.each do |product|
            type_id = product["type"].to_i
            kind = KIND_BY_PRODUCT_TYPE[type_id]
            if kind.nil?
              stdout.puts "  Skipping product type #{type_id} (#{product['alias'] || product['name']})"
              next
            end

            uuid = product["uuid"]
            stdout.puts "  Fetching movements for #{product['alias'] || product['name']} (#{kind})..."

            begin
              movements = client.legacy_fetch_all_movements(v1id: uuid, from_date: from_date)
              product["movements"] = movements
              stdout.puts "    → #{movements.size} movements"
            rescue StandardError => error
              stderr.puts "    ✗ #{error.class}: #{error.message}"
              product["movements"] = []
            end
          end

          products
        end
      end
    end
  end
end

# frozen_string_literal: true

# ING extractor: fetches products (accounts + cards) via the legacy
# genoma_api endpoint, then per-product movements. The resulting raw
# payload is an Array of product hashes, each with a "movements" key
# holding the raw movement list returned by the API.
#
# Extracted from scripts/lib/push_data/sources/ing.rb#fetch_payload.
module Freentonic
  module Providers
    module Ing
      class Extractor
        # Same mapping as app/services/bank_sync/ing/sync_service.rb KIND_BY_PRODUCT_TYPE.
        # Kept here (not in the YAML) so the Extractor can log which products
        # it skipped and why.
        KIND_BY_PRODUCT_TYPE = {
          1  => nil,           # debit card — not a balance-bearing account
          3  => "liability",   # Tarjeta Crédito
          10 => "asset",       # Cuenta de efectivo
          17 => "asset",       # Cuenta SIN NÓMINA
          20 => "asset",       # Cuenta NARANJA
          42 => "investment"   # Cuenta de valores
        }.freeze

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

# frozen_string_literal: true

# Unicaja extractor: fetches cuentas + tarjetas + préstamos, then
# per-product movements. Produces a Hash with four slots that the
# normalizer consumes. Ported from
# scripts/lib/push_data/sources/unicaja.rb#fetch_payload.
module Freentonic
  module Providers
    module Unicaja
      class Extractor
        def call(client:, credentials:, from_date:, stdout:, stderr:)
          stdout.puts "  Fetching cuentas..."
          raw_cuentas = client.fetch_listacuentas
          cuentas = raw_cuentas.is_a?(Hash) ? (raw_cuentas["cuentas"] || raw_cuentas["listaCuentas"] || []) : Array(raw_cuentas)
          stdout.puts "    → #{cuentas.size} cuentas"

          stdout.puts "  Fetching tarjetas..."
          raw_tarjetas = client.fetch_listatarjetas
          tarjetas = raw_tarjetas.is_a?(Hash) ? (raw_tarjetas["tarjetas"] || raw_tarjetas["listaTarjetas"] || []) : Array(raw_tarjetas)
          stdout.puts "    → #{tarjetas.size} tarjetas"

          stdout.puts "  Fetching préstamos..."
          raw_prestamos = begin
            client.fetch_listaprestamos
          rescue StandardError => error
            stderr.puts "    ✗ #{error.class}: #{error.message}"
            {}
          end
          prestamos = Array(raw_prestamos["prestamos"]) + Array(raw_prestamos["prestamosAvalados"])
          stdout.puts "    → #{prestamos.size} préstamos"

          cuenta_movements = {}
          cuentas.each do |cuenta|
            ppp = cuenta["ppp"] || cuenta["codigoProducto"]
            next unless ppp

            stdout.puts "  Fetching movements for cuenta #{ppp}..."
            begin
              movements = client.fetch_all_account_movements(ppp: ppp, fecha_desde: from_date.to_s)
              cuenta_movements[ppp] = movements
              stdout.puts "    → #{movements.size} movements"
            rescue StandardError => error
              stderr.puts "    ✗ #{error.class}: #{error.message}"
              cuenta_movements[ppp] = []
            end
          end

          tarjeta_movements = {}
          tarjetas.each do |tarjeta|
            ppp = tarjeta["ppp"] || tarjeta["codigoProducto"]
            next unless ppp

            cod = tarjeta["codtipotarjeta"].to_s
            tipo = "#{tarjeta['tipotarjeta']} #{tarjeta['descripcion']}".downcase
            is_credit = cod == "2" || tipo.include?("credit") || tipo.include?("créd")
            unless is_credit
              stdout.puts "  Skipping debit card #{ppp}"
              next
            end

            stdout.puts "  Fetching movements for tarjeta #{ppp}..."
            begin
              movements = client.fetch_all_card_movements(ppp: ppp, fecha_desde: from_date.to_s)
              tarjeta_movements[ppp] = movements
              stdout.puts "    → #{movements.size} movements"
            rescue StandardError => error
              stderr.puts "    ✗ #{error.class}: #{error.message}"
              tarjeta_movements[ppp] = []
            end
          end

          {
            "cuentas"           => cuentas,
            "tarjetas"          => tarjetas,
            "prestamos"         => prestamos,
            "cuenta_movements"  => cuenta_movements,
            "tarjeta_movements" => tarjeta_movements
          }
        end
      end
    end
  end
end

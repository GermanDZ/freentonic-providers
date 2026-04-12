# frozen_string_literal: true

require "date"

# Unicaja extractor: fetches cuentas + tarjetas + prestamos, then
# per-product movements. Produces a Hash with four slots that the
# normalizer consumes. Ported from
# scripts/lib/push_data/sources/unicaja.rb#fetch_payload.
#
# Two movement-fetch paths:
#   1. Standard  (<=30 days) — /services/rest/api/cuentas/movimientos
#      Always runs. No OTP required.
#   2. Extended  (>30 days)  — /apis/externo/.../busqueda (paginated)
#      Only runs when from_date is >30 days ago. Requires the session
#      to have been armed via the pre_arm_history browser phase (OTP).
#      Results are merged with the standard fetch and deduplicated.
module Freentonic
  module Providers
    module Unicaja
      class Extractor
        RECENT_WINDOW_DAYS = 30
        MAX_MOVEMENTS_SAFETY_CAP = 10_000

        def call(client:, credentials:, from_date:, stdout:, stderr:)
          stdout.puts "  Fetching cuentas..."
          raw_cuentas = client.fetch_listacuentas
          cuentas = raw_cuentas.is_a?(Hash) ? (raw_cuentas["cuentas"] || raw_cuentas["listaCuentas"] || []) : Array(raw_cuentas)
          stdout.puts "    -> #{cuentas.size} cuentas"

          stdout.puts "  Fetching tarjetas..."
          raw_tarjetas = client.fetch_listatarjetas
          tarjetas = raw_tarjetas.is_a?(Hash) ? (raw_tarjetas["tarjetas"] || raw_tarjetas["listaTarjetas"] || []) : Array(raw_tarjetas)
          stdout.puts "    -> #{tarjetas.size} tarjetas"

          stdout.puts "  Fetching prestamos..."
          raw_prestamos = begin
            client.fetch_listaprestamos
          rescue StandardError => error
            stderr.puts "    x #{error.class}: #{error.message}"
            {}
          end
          prestamos = Array(raw_prestamos["prestamos"]) + Array(raw_prestamos["prestamosAvalados"])
          stdout.puts "    -> #{prestamos.size} prestamos"

          extended = (Date.today - from_date).to_i > RECENT_WINDOW_DAYS
          recent_from = extended ? (Date.today - RECENT_WINDOW_DAYS) : from_date

          cuenta_movements = {}
          cuentas.each do |cuenta|
            ppp = cuenta["ppp"] || cuenta["codigoProducto"]
            next unless ppp

            # 1) Standard fetch — always runs (recent window)
            stdout.puts "  Fetching movements for cuenta #{ppp}..."
            begin
              recent = client.fetch_all_account_movements(ppp: ppp, fecha_desde: recent_from.to_s)
              stdout.puts "    -> #{recent.size} movements (standard)"
            rescue StandardError => error
              stderr.puts "    x #{error.class}: #{error.message}"
              recent = []
            end

            # 2) Extended fetch — only when >30 days (armed session required)
            if extended
              stdout.puts "  Fetching extended history for cuenta #{ppp}..."
              begin
                old = fetch_extended_movements(
                  client:    client,
                  ppp:       ppp,
                  from_date: from_date,
                  to_date:   recent_from,
                  stdout:    stdout
                )
                stdout.puts "    -> #{old.size} movements (extended)"
                cuenta_movements[ppp] = merge_movements(old, recent)
                stdout.puts "    -> #{cuenta_movements[ppp].size} movements total (deduplicated)"
              rescue StandardError => error
                stderr.puts "    x extended fetch failed: #{error.class}: #{error.message}"
                cuenta_movements[ppp] = recent
              end
            else
              cuenta_movements[ppp] = recent
            end
          end

          tarjeta_movements = {}
          tarjetas.each do |tarjeta|
            ppp = tarjeta["ppp"] || tarjeta["codigoProducto"]
            next unless ppp

            cod = tarjeta["codtipotarjeta"].to_s
            tipo = "#{tarjeta['tipotarjeta']} #{tarjeta['descripcion']}".downcase
            is_credit = cod == "2" || tipo.include?("credit") || tipo.include?("cred")
            unless is_credit
              stdout.puts "  Skipping debit card #{ppp}"
              next
            end

            stdout.puts "  Fetching movements for tarjeta #{ppp}..."
            begin
              movements = client.fetch_all_card_movements(ppp: ppp, fecha_desde: from_date.to_s)
              tarjeta_movements[ppp] = movements
              stdout.puts "    -> #{movements.size} movements"
            rescue StandardError => error
              stderr.puts "    x #{error.class}: #{error.message}"
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

        private

        # Cursor-paginated fetch over the /apis/externo/.../busqueda endpoint.
        # The endpoint returns the full JSON hash (no extract_batch) so we can
        # read both `movimientos` and `masMovimientos`.
        #
        # Pagination cursors come from masMovimientos (NOT from the last row):
        #   masMovimientos.numUltimoMovimiento  -> numUltMov
        #   masMovimientos.ultimoSaldo.cantidad  -> saldoUltMov
        #   masMovimientos.indMasMovimientos     -> "S" = more pages
        #
        # First request: indOperacion="I", no cursor params.
        # Next requests: indOperacion="P" + cursor values from masMovimientos.
        def fetch_extended_movements(client:, ppp:, from_date:, to_date:, stdout:)
          all           = []
          ind_operacion = "I"
          saldo_ult_mov = nil
          num_ult_mov   = nil

          loop do
            raw = client.fetch_account_movements_page(
              ppp:           ppp,
              ind_operacion: ind_operacion,
              fecha_desde:   from_date.to_s,
              fecha_hasta:   to_date.to_s,
              saldo_ult_mov: saldo_ult_mov,
              num_ult_mov:   num_ult_mov
            )
            break if raw.nil?

            movimientos = extract_movimientos(raw)
            break if movimientos.empty?

            all.concat(movimientos)

            if all.size >= MAX_MOVEMENTS_SAFETY_CAP
              stdout.puts "    ! hit MAX_MOVEMENTS_SAFETY_CAP (#{MAX_MOVEMENTS_SAFETY_CAP}); stopping"
              break
            end

            mas = raw["masMovimientos"]
            stdout.puts "    -> fetched #{all.size} so far"
            break unless mas && mas["indMasMovimientos"] == "S"

            num_ult_mov   = mas["numUltimoMovimiento"]
            saldo_ult_mov = mas.dig("ultimoSaldo", "cantidad")
            if num_ult_mov.nil? || saldo_ult_mov.nil?
              stdout.puts "    ! masMovimientos cursor incomplete; stopping"
              break
            end
            ind_operacion = "P"
          end

          all
        end

        def extract_movimientos(raw)
          return raw if raw.is_a?(Array)
          return [] unless raw.is_a?(Hash)
          raw["movimientos"] || raw["listaMovimientos"] || []
        end

        # Merge extended (older) + recent movements, deduplicating by
        # numMovimiento when present.
        def merge_movements(old_movements, recent_movements)
          all = old_movements + recent_movements
          seen = {}
          all.select do |mov|
            key = mov["numMovimiento"]
            if key.nil?
              true
            elsif seen[key]
              false
            else
              seen[key] = true
            end
          end
        end
      end
    end
  end
end

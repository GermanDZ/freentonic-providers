# frozen_string_literal: true

# Unicaja normalizer: converts the Extractor's raw product/movement hash
# into the universal account/movement shape that freentonic HTTP receivers
# are expected to accept. The exact receiver spec is defined by the ingest
# system you export to.

require "date"
require "digest"

module Freentonic
  module Providers
    module Unicaja
      class Normalizer < Freentonic::Normalizers::Base
        def call(raw, context: {})
          @cuentas           = Array(raw["cuentas"])
          @tarjetas          = Array(raw["tarjetas"])
          @prestamos         = Array(raw["prestamos"])
          @cuenta_movements  = raw["cuenta_movements"] || {}
          @tarjeta_movements = raw["tarjeta_movements"] || {}

          accounts = []
          accounts.concat(@cuentas.filter_map  { |c| build_cuenta(c) })
          accounts.concat(@tarjetas.filter_map { |t| build_tarjeta(t) })
          accounts.concat(@prestamos.filter_map { |l| build_prestamo(l) })

          { "source_tag" => "unicaja_push", "accounts" => accounts }
        end

        private

        def presence(str)
          s = str.to_s.strip
          s.empty? ? nil : s
        end

        def build_cuenta(c)
          ppp = c["ppp"] || c["codigoProducto"] || c["id"]
          return nil unless ppp

          movements = (@cuenta_movements[ppp] || []).filter_map { |mv| build_movement(ppp, mv) }

          {
            "external_id"    => "unicaja_live:cuenta:#{ppp}",
            "legacy_uids"    => ["unicaja_live:cuenta:#{ppp}"],
            "iban"           => c["iban"] || c["IBAN"],
            "kind"           => "asset",
            "bank_key"       => "unicaja",
            "name"           => c["alias"].to_s.strip.empty? ? (presence(c["descripcion"]) || "Unicaja #{ppp}") : c["alias"],
            "currency"       => c["divisa"] || c["moneda"] || "EUR",
            "balance_cents"  => extract_balance_cents(c),
            "balance_source" => "unicaja_live:listacuentas",
            "metadata"       => { "unicaja_ppp" => ppp, "unicaja_kind" => "cuenta" },
            "movements"      => movements
          }
        end

        def build_tarjeta(t)
          ppp = t["ppp"] || t["codigoProducto"] || t["id"]
          return nil unless ppp
          return nil unless credit_card?(t)

          movements = (@tarjeta_movements[ppp] || []).filter_map { |mv| build_movement(ppp, mv) }

          balance_cents = extract_card_balance_cents(t)

          {
            "external_id"    => "unicaja_live:tarjeta:#{ppp}",
            "legacy_uids"    => ["unicaja_live:tarjeta:#{ppp}"],
            "kind"           => "liability",
            "bank_key"       => "unicaja_cc",
            "name"           => t["alias"].to_s.strip.empty? ? (presence(t["tipotarjeta"]) || presence(t["descripcion"]) || "Unicaja card #{ppp}") : t["alias"],
            "currency"       => t["divisa"] || t["moneda"] || "EUR",
            "balance_cents"  => balance_cents,
            "balance_source" => balance_cents ? "unicaja_live:listatarjetas" : nil,
            "metadata"       => { "unicaja_ppp" => ppp, "unicaja_kind" => "tarjeta", "unicaja_codtipotarjeta" => t["codtipotarjeta"] },
            "movements"      => movements
          }
        end

        def build_prestamo(l)
          ppp = l["ppp"]
          return nil unless ppp

          balance_cents = if l.dig("saldo", "cantidad").is_a?(Numeric)
                            (l.dig("saldo", "cantidad").to_f * 100).round
                          end

          {
            "external_id"    => "unicaja_live:prestamo:#{ppp}",
            "legacy_uids"    => ["unicaja_live:prestamo:#{ppp}"],
            "kind"           => "liability",
            "bank_key"       => "unicaja_loan",
            "name"           => l["alias"].to_s.strip.empty? ? (presence(l["descripcion"]) || "Unicaja loan #{ppp}") : l["alias"],
            "currency"       => l.dig("saldo", "moneda") || "EUR",
            "balance_cents"  => balance_cents,
            "balance_source" => balance_cents ? "unicaja_live:listaprestamos" : nil,
            "metadata"       => { "unicaja_ppp" => ppp, "unicaja_kind" => "prestamo", "unicaja_loan_type" => detect_loan_type(l) },
            "movements"      => []
          }
        end

        def build_movement(ppp, mv)
          mv_id = movement_id(mv)
          return nil unless mv_id

          amount_cents = extract_amount_cents(mv)
          return nil unless amount_cents && amount_cents != 0

          date = parse_date(mv["fechaOperacion"] || mv["fechaoper"] || mv["fechaValor"] || mv["fechavalor"] || mv["fecha"])
          return nil unless date

          description = mv["concepto"] || mv["nombreComercio"] || mv["descripcionOper"] || mv["descripcion"]

          {
            "dedup_key"    => "unicaja_live:#{ppp}:#{mv_id}",
            "date"         => date.strftime("%Y-%m-%d"),
            "amount_cents" => amount_cents,
            "currency"     => extract_currency(mv) || "EUR",
            "description"  => description.to_s.strip,
            "raw_payload"  => { "unicaja_movement" => mv, "ppp" => ppp }
          }
        end

        def movement_id(mv)
          mv["numMovimiento"] || mv["nummov"] || mv["idMovimiento"] || mv["referenciaUnica"] || mv["id"] || begin
            parts = [mv["fechaOperacion"] || mv["fechaoper"], mv["importe"], mv["concepto"] || mv["nombreComercio"]].map(&:to_s).join("|")
            "h:#{Digest::SHA1.hexdigest(parts)[0, 16]}"
          end
        end

        def extract_amount_cents(mv)
          raw = mv["importe"] || mv["importeMovimiento"] || mv["cantidad"] || mv["amount"]
          return nil if raw.nil?
          float = case raw
                  when Hash    then (raw["cantidad"] || raw["importe"] || raw["value"])&.to_f
                  when Numeric then raw.to_f
                  when String  then raw.tr(",", ".").to_f
                  end
          float ? (float * 100).round : nil
        end

        def extract_currency(mv)
          raw = mv["importe"] || mv["importeMovimiento"]
          return raw["divisa"] || raw["moneda"] if raw.is_a?(Hash)
          mv["divisa"] || mv["moneda"]
        end

        def extract_balance_cents(p)
          raw = p["saldo"] || p["saldoActual"] || p["saldoDisponible"] || p["balance"]
          return nil if raw.nil?
          float = case raw
                  when Hash    then (raw["cantidad"] || raw["importe"] || raw["value"])&.to_f
                  when Numeric then raw.to_f
                  when String  then raw.tr(",", ".").to_f
                  end
          float ? (float * 100).round : nil
        end

        def extract_card_balance_cents(t)
          limite     = t.dig("limite", "cantidad")
          disponible = t.dig("disponible", "cantidad")
          return nil unless limite.is_a?(Numeric) && disponible.is_a?(Numeric)
          ((limite - disponible) * 100).round
        end

        def credit_card?(t)
          return true if t["codtipotarjeta"].to_s == "2"
          tipo = "#{t["tipotarjeta"]} #{t["descripcion"]}".downcase
          tipo.include?("credit") || tipo.include?("créd")
        end

        def detect_loan_type(l)
          return "mortgage" if l["indPrestamoHipotecario"].to_s == "S"
          desc = "#{l["descripcion"]} #{l["alias"]}".downcase
          return "mortgage" if desc.include?("hipot")
          "loan"
        end

        def parse_date(str)
          return nil if str.to_s.empty?
          Date.parse(str)
        rescue Date::Error
          begin
            Date.strptime(str, "%d/%m/%Y")
          rescue Date::Error
            nil
          end
        end
      end
    end
  end
end

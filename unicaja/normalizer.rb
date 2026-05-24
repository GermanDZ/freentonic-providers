# frozen_string_literal: true

require "date"
require "digest"
require "bigdecimal"
require "freentonic"

module Freentonic
  module Providers
    module Unicaja
      class Normalizer < Freentonic::Providers::NormalizerBase
        provider!(__dir__)
        # CONFIG, INSTITUTION, SCRAPER_VERSION, BANK_CODE,
        # UNICAJA_DATE_FORMATS, FIELD_ALIASES come from
        # unicaja/config.yml. Builder, Helpers inherited.

        def call(raw, context: {})
          @cuenta_movements  = raw["cuenta_movements"] || {}
          @tarjeta_movements = raw["tarjeta_movements"] || {}

          accounts, liabilities, transactions = [], [], []

          Array(raw["cuentas"]).each do |c|
            account = build_cuenta(c)
            next unless account
            accounts << account
            transactions.concat(build_transactions(account, ppp_for(c), @cuenta_movements[ppp_for(c)]))
          end

          Array(raw["tarjetas"]).each do |t|
            next unless credit_card?(t)
            account = build_tarjeta(t)
            next unless account
            accounts << account
            liabilities << build_card_liability(t, account)
            transactions.concat(build_transactions(account, ppp_for(t), @tarjeta_movements[ppp_for(t)]))
          end

          Array(raw["prestamos"]).each do |l|
            account = build_prestamo_account(l)
            next unless account
            accounts << account
            liabilities << build_loan_liability(l, account)
          end

          Builder.payload(
            accounts:     accounts,
            transactions: transactions,
            liabilities:  liabilities,
            scraper_version: SCRAPER_VERSION
          )
        end

        private

        # --- Cuenta (checking) ------------------------------------------------

        def build_cuenta(c)
          ppp = ppp_for(c)
          return nil unless ppp
          balance_cents = extract_balance_cents(c)
          iban = pick(:iban, c)
          portable_ref, portable_id = Builder.spanish_iban_portable_keys(iban, bank_code: BANK_CODE)

          Builder.build_account(
            institution: INSTITUTION,
            source_id:   "cuenta:#{ppp}",
            currency:    pick(:currency, c) || "EUR",
            name:        first_present(c["alias"], c["descripcion"], "Unicaja #{ppp}"),
            type:        "checking",
            iban:        iban,
            portable_ref: portable_ref,
            portable_id:  portable_id,
            balance: {
              current:   Builder.cents_to_amount(balance_cents),
              timestamp: nil
            },
            metadata: {
              "unicaja_ppp"    => ppp,
              "unicaja_kind"   => "cuenta",
              "balance_source" => "unicaja_live:listacuentas"
            }
          )
        end

        # --- Tarjeta (credit card) -------------------------------------------

        def build_tarjeta(t)
          ppp = ppp_for(t)
          return nil unless ppp
          # Outstanding is positive cents (limite - disponible). The
          # canonical convention is that credit-card *account* balances
          # are stored NEGATIVE — same orientation as ING's liability
          # accounts (see ing/normalizer.rb#extract_balance), so a card
          # with €200 owed appears as -200.00 to the user. The same
          # outstanding figure is reused positively on the companion
          # liability record where "amount owed" is the convention.
          outstanding_cents = extract_card_balance_cents(t)
          balance_cents     = outstanding_cents ? -outstanding_cents : nil
          portable_ref, portable_id = Builder.card_pan_portable_keys(
            t["numtarjeta"] || t["numeroTarjeta"], bank_code: BANK_CODE
          )

          Builder.build_account(
            institution: INSTITUTION,
            source_id:   "tarjeta:#{ppp}",
            currency:    pick(:currency, t) || "EUR",
            name:        first_present(t["alias"], t["tipotarjeta"], "Unicaja card #{ppp}", t["descripcion"]),
            type:        "credit_card",
            iban:        nil,
            portable_ref: portable_ref,
            portable_id:  portable_id,
            balance: {
              current:   Builder.cents_to_amount(balance_cents),
              timestamp: nil
            },
            metadata: {
              "unicaja_ppp"            => ppp,
              "unicaja_kind"           => "tarjeta",
              "unicaja_codtipotarjeta" => t["codtipotarjeta"],
              "balance_source"         => balance_cents ? "unicaja_live:listatarjetas" : nil
            }
          )
        end

        def build_card_liability(t, account)
          limit_cents   = cents(t.dig("limite", "cantidad"))
          balance_cents = extract_card_balance_cents(t)
          Builder.build_liability(
            account_id: account.id,
            type:       "credit_card",
            currency:   account.currency,
            source_id:  "tarjeta:#{ppp_for(t)}",
            balance:    Builder.cents_to_amount(balance_cents),
            limit:      Builder.cents_to_amount(limit_cents),
            metadata:   { "unicaja_codtipotarjeta" => t["codtipotarjeta"] }
          )
        end

        # --- Prestamo (loan / mortgage) --------------------------------------

        def build_prestamo_account(l)
          ppp = l["ppp"]
          return nil unless ppp
          balance_cents = prestamo_balance_cents(l)

          Builder.build_account(
            institution: INSTITUTION,
            source_id:   "prestamo:#{ppp}",
            currency:    l.dig("saldo", "moneda") || "EUR",
            name:        first_present(l["alias"], l["descripcion"], "Unicaja loan #{ppp}"),
            type:        "loan",
            iban:        nil,
            balance: {
              current:   Builder.cents_to_amount(balance_cents),
              timestamp: nil
            },
            metadata: {
              "unicaja_ppp"       => ppp,
              "unicaja_kind"      => "prestamo",
              "unicaja_loan_type" => detect_loan_type(l),
              "balance_source"    => balance_cents ? "unicaja_live:listaprestamos" : nil
            }
          )
        end

        def build_loan_liability(l, account)
          balance_cents = prestamo_balance_cents(l)
          Builder.build_liability(
            account_id: account.id,
            type:       detect_loan_type(l),
            currency:   account.currency,
            source_id:  "prestamo:#{l["ppp"]}",
            balance:    Builder.cents_to_amount(balance_cents),
            metadata:   { "unicaja_loan_type" => detect_loan_type(l) }
          )
        end

        # --- Movements -------------------------------------------------------

        def build_transactions(account, ppp, movements)
          return [] unless movements.is_a?(Array)
          movements.filter_map { |mv| build_transaction(account, ppp, mv) }
        end

        def build_transaction(account, ppp, mv)
          mv_id = movement_id(mv)
          return nil unless mv_id

          amount_cents = extract_amount_cents(mv)
          return nil unless amount_cents && amount_cents != 0

          date = parse_date(pick(:date, mv), preferred_formats: UNICAJA_DATE_FORMATS)
          return nil unless date

          raw_description = pick(:description_raw, mv).to_s
          cleaned_desc = pick(:description, mv).to_s.strip

          Builder.build_transaction(
            account_id:      account.id,
            source_id:       mv_id,
            amount:          Builder.cents_to_amount(amount_cents),
            currency:        extract_currency(mv) || account.currency,
            date:            date,
            description:     cleaned_desc,
            raw_description: raw_description,
            metadata:        { "unicaja_movement" => mv, "ppp" => ppp }
          )
        end

        # --- Helpers ---------------------------------------------------------

        def ppp_for(product)
          pick(:ppp, product)
        end

        # Stable id with a hash fallback when the bank emits no movement
        # key at all. The hash uses the same logical fields the alias
        # map declares — keep them in sync if a new endpoint surfaces
        # additional spellings.
        def movement_id(mv)
          pick(:movement_id, mv) || begin
            parts = [pick(:date, mv), mv["importe"], pick(:description, mv)]
                    .map(&:to_s).join("|")
            "h:#{Digest::SHA1.hexdigest(parts)[0, 16]}"
          end
        end

        def extract_amount_cents(mv)
          cents(pick(:raw_amount, mv))
        end

        def extract_currency(mv)
          raw = pick(:raw_amount, mv)
          return pick(:currency, raw) if raw.is_a?(Hash)
          pick(:currency, mv)
        end

        def extract_balance_cents(p)
          cents(pick(:balance, p))
        end

        # Card outstanding = limite - disponible (in cents).
        def extract_card_balance_cents(t)
          limite     = t.dig("limite", "cantidad")
          disponible = t.dig("disponible", "cantidad")
          return nil unless limite.is_a?(Numeric) && disponible.is_a?(Numeric)
          ((limite - disponible) * 100).round
        end

        def prestamo_balance_cents(l)
          raw = l.dig("saldo", "cantidad")
          return nil unless raw.is_a?(Numeric)
          (raw.to_f * 100).round
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

      end
    end
  end
end

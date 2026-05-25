# frozen_string_literal: true

require "date"
require "bigdecimal"
require "freentonic"
require_relative "extractor"

module Freentonic
  module Providers
    module Ing
      class Normalizer < Freentonic::Providers::NormalizerBase
        provider!(__dir__)
        # CONFIG, INSTITUTION, SCRAPER_VERSION, BANK_CODE,
        # KIND_BY_PRODUCT_TYPE, ING_DATE_FORMATS, STATUS_MAP,
        # FIELD_ALIASES all come from ing/config.yml. Builder, Helpers
        # inherited.

        def call(raw, context: {})
          accounts, liabilities, transactions = [], [], []
          products = Array(raw)
          # Per-plastic credit-card balances, reconciled per revolving line.
          # Computed up front because the figure for any one plastic depends
          # on its line siblings (see #compute_cc_balances).
          cc_balances = compute_cc_balances(products)

          products.each do |product|
            kind = KIND_BY_PRODUCT_TYPE[product["type"].to_i]
            next if kind.nil?

            account = build_account(product, kind, cc_balances)
            accounts << account

            if kind == "liability"
              liabilities << build_liability(product, account)
            end

            Array(product["movements"]).each do |mv|
              txn = build_transaction(product, account, mv)
              transactions << txn if txn
            end
          end

          transactions = collapse_pre_clearing_dups(transactions)

          Builder.payload(
            accounts:     accounts,
            transactions: transactions,
            liabilities:  liabilities,
            scraper_version: SCRAPER_VERSION
          )
        end

        private

        # ING's /v2/products/transactions/search re-emits the same real
        # posting under two `transactionSequence`s while it transitions
        # from pre-clearing (terse description) to post-clearing
        # (enriched description). Without collapse, every fetch overlapping
        # that window produces two canonical transactions for one posting
        # ("dup-class-2"). Drop the shorter row when the longer row's
        # description (whitespace-normalized) starts with the shorter
        # row's description verbatim — that's the pre-clearing terse form.
        # Identical descriptions remain (real twins, e.g. two €80 fees to
        # the same town hall on the same day). Descriptions that diverge
        # mid-string remain (truly distinct postings on the same key).
        def collapse_pre_clearing_dups(transactions)
          transactions
            .group_by { |t| [t.account_id, t.date, t.amount] }
            .flat_map { |_, txs| collapse_one_group(txs) }
        end

        def collapse_one_group(txs)
          return txs if txs.size <= 1

          normalized = txs.map { |t| [t, compact_whitespace(t.description)] }
          return txs if normalized.map(&:last).uniq.size == 1   # real twins

          longest = normalized.max_by { |_, d| d.length }
          others  = normalized - [longest]
          if others.all? { |_, d| longest.last.start_with?(d) && d.length < longest.last.length }
            [longest.first]
          else
            txs
          end
        end

        # ING issues one product per plastic card. We emit one canonical
        # Account per plastic so each plastic carries its own portable_ref
        # (BANKID:PAN_LAST4), which is what cross-source matching with
        # Fintonic — and any future card-level merge layer — joins on.
        #
        # Balance: `creditLimit`/`availableBalance` are LINE-level (shared by
        # every plastic on the same revolving line), so they used to be
        # emitted identically on every plastic — and any downstream that
        # sums accounts (Sure, Actual) multi-counted the debt. ING also
        # exposes a PER-PLASTIC `monthPurchasesAmount`, and those sum to the
        # line's `limit − available` exactly (verified against the bank).
        # We now emit each plastic's own `monthPurchasesAmount` — exactly what
        # the ING app shows as that card's balance (verified). We don't
        # reconcile to `limit − available`, which can include pending holds
        # the bank posts to no card (see #compute_cc_balances). Net effect:
        # no duplication, per-card balances matching the bank app, fully live
        # — no operator balance_override needed.

        def build_account(product, kind, cc_balances = {})
          uuid = product["uuid"]
          iban = product["iban"].to_s.gsub(/\s/, "")
          iban = nil if iban.empty?
          balance_cents, balance_source =
            if kind == "liability"
              cc_balances[product["productNumber"]] || [nil, nil]
            else
              extract_asset_balance(product)
            end

          portable_ref, portable_id =
            if kind == "liability"
              Builder.card_pan_portable_keys(product["productNumber"], bank_code: BANK_CODE)
            else
              Builder.spanish_iban_portable_keys(iban, bank_code: BANK_CODE)
            end

          Builder.build_account(
            institution: INSTITUTION,
            source_id:   uuid,
            currency:    product["currency"] || "EUR",
            name:        pick_name(product),
            type:        kind == "liability" ? "credit_card" : "checking",
            iban:        iban,
            portable_ref: portable_ref,
            portable_id:  portable_id,
            balance:     { current: Builder.cents_to_amount(balance_cents), timestamp: nil },
            metadata: {
              "ing_product_type"        => product["type"],
              "ing_product_number"      => product["productNumber"],
              "balance_source"          => balance_source,
              "ing_month_purchases"     => (kind == "liability" ? product["monthPurchasesAmount"] : nil),
              "partial_data_suspected"  => product["_partial_data_suspected"]
            }.compact
          )
        end

        # Asset products carry a top-level numeric `balance` (the cleared
        # account balance), emitted verbatim (positive).
        def extract_asset_balance(product)
          if product["balance"].is_a?(Numeric)
            [(product["balance"].to_f * 100).round, "ing_live:product_balance"]
          else
            [nil, nil]
          end
        end

        # Per-plastic credit-card balances, one per revolving line.
        #
        # Returns { productNumber => [balance_cents (negative = owed), source] }.
        #
        # ING reports `creditLimit`/`availableBalance` at the LINE level
        # (identical on every plastic of a line) and a PER-plastic
        # `monthPurchasesAmount`. The per-plastic figure is exactly what the
        # ING app shows as each card's balance (verified against the app:
        # 1380.25 + 2529.07), so we emit it verbatim.
        #
        # We deliberately DON'T reconcile to the line's `limit − available`.
        # That figure can exceed the sum of the posted per-card balances
        # because it also reflects pending authorizations / holds the bank
        # hasn't posted to any plastic; topping a card up to it would inflate
        # that card past what the bank app shows. (`spentAmount` is ignored
        # too — observed reporting a stale non-zero figure on a paid line.)
        #
        # Fallback: only when a line exposes NO per-plastic purchases at all
        # do we fall back to putting the whole line outstanding on the carrier
        # (active principal) and zeroing the rest, so the debt isn't lost or
        # multi-counted.
        def compute_cc_balances(products)
          ccs = Array(products).select do |p|
            p.is_a?(Hash) && KIND_BY_PRODUCT_TYPE[p["type"].to_i] == "liability"
          end

          out = {}
          ccs.group_by { |p| cc_line_key(p) }.each_value do |line_cards|
            if line_cards.any? { |p| !month_purchases_cents(p).nil? }
              line_cards.each do |p|
                out[p["productNumber"]] = [-(month_purchases_cents(p) || 0), "ing_live:card_purchases"]
              end
            elsif (line_total = line_outstanding_cents(line_cards.first))
              carrier = pick_line_carrier(line_cards)
              line_cards.each do |p|
                cents = p.equal?(carrier) ? line_total : 0
                out[p["productNumber"]] = [-cents, "ing_live:line_outstanding"]
              end
            else
              line_cards.each { |p| out[p["productNumber"]] = [nil, nil] }
            end
          end
          out
        end

        # Line identity: plastics on the same revolving line share both the
        # billing account and the credit limit. (All of a household's cards
        # can bill to one current account, so the limit is needed too.)
        def cc_line_key(product)
          [product.dig("associatedAccount", "productNumber"), product["creditLimit"]]
        end

        # Authoritative outstanding for the whole line, in cents (positive
        # when money is owed). nil when ING didn't expose the line figures.
        def line_outstanding_cents(product)
          limit     = product["creditLimit"]
          available = product["availableBalance"]
          return nil unless limit.is_a?(Numeric) && available.is_a?(Numeric)
          ((limit.to_f - available.to_f) * 100).round
        end

        def month_purchases_cents(product)
          mp = product["monthPurchasesAmount"]
          mp.is_a?(Numeric) ? (mp.to_f * 100).round : nil
        end

        # Carrier = the plastic that absorbs any unattributed line remainder.
        # Prefer the principal cardholder's card, then the highest current
        # spend, then lowest PAN for determinism.
        def pick_line_carrier(cards)
          cards.min_by do |p|
            principal = p.dig("holder", "type") == "Principal" ? 0 : 1
            [principal, -(month_purchases_cents(p) || 0), p["productNumber"].to_s]
          end
        end

        def build_liability(product, account)
          Builder.build_liability(
            account_id: account.id,
            type:       "credit_card",
            currency:   account.currency,
            source_id:  product["uuid"],
            metadata:   {
              "ing_product_type"   => product["type"],
              "ing_product_number" => product["productNumber"]
            }
          )
        end

        def build_transaction(_product, account, mv)
          mv_uuid = mv["uuid"]
          return nil unless mv_uuid

          amount = mv["amount"]
          return nil unless amount.is_a?(Numeric) && amount != 0

          date = parse_date(pick(:date, mv), preferred_formats: ING_DATE_FORMATS)
          return nil unless date

          # ING returns a top-line `description` ("Recibo ESCUELA NUEVA
          # KEPLER, S.L.") and a sub-line `store` carrying per-line
          # detail — the kid's name on a school fee, the meter number on
          # a utility bill, the specific REFERENCIA/RECIBO on a SEPA
          # debit. Two real postings on the same day for the same amount
          # (typical "one fee per kid" case) share the top line but
          # differ in `store`. Earlier versions kept only `description`,
          # so legitimate twin postings collapsed to byte-identical
          # canonical text and downstream SimpleFIN consumers couldn't
          # tell them apart. Concatenate so the disambiguator reaches
          # clients. See simplefreen/reports/simplefreen-dup-r3-post-fix.md
          # for the incident this surfaced.
          parts = [mv["description"], compact_whitespace(mv["store"])]
                  .map { |s| s.to_s.strip }.reject(&:empty?)
          raw_description = parts.join(" — ")
          cleaned = raw_description

          Builder.build_transaction(
            account_id: account.id,
            source_id:  mv_uuid,
            amount:     amount,
            currency:   mv["currency"] || "EUR",
            date:       date,
            value_date: parse_date(mv["clearingDate"], preferred_formats: ING_DATE_FORMATS),
            description:     cleaned,
            raw_description: raw_description,
            status:     Builder.map_status_from(mv.dig("status", "description"), STATUS_MAP) ||
                        Freentonic::Canonical::Transaction::POSTED,
            metadata:   { "ing" => extract_fields(mv, RAW_FIELDS_MOVEMENT) }
          )
        end

        def pick_name(product)
          first_present(product["alias"], product["name"]) || "ING"
        end

        def compact_whitespace(str)
          return nil if str.nil?
          str.to_s.gsub(/\s+/, " ").strip
        end

      end
    end
  end
end

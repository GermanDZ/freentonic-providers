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
        # CONFIG, INSTITUTION, SCRAPER_VERSION, KIND_BY_PRODUCT_TYPE,
        # ING_DATE_FORMATS, ING_PENDING_STATUS all come from
        # ing/config.yml. Builder, Helpers inherited.

        def call(raw, context: {})
          accounts, liabilities, transactions = [], [], []

          Array(raw).each do |product|
            kind = KIND_BY_PRODUCT_TYPE[product["type"].to_i]
            next if kind.nil?

            account = build_account(product, kind)
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
        # Fintonic — and any future card-level merge layer — joins on. The
        # framework treats balance/liability as per-Account; line-level
        # debt that's actually shared across plastics on the same revolving
        # credit line (creditLimit/availableBalance is line-level, not
        # plastic-level) gets emitted on every plastic and the consolidation
        # layer in simplefreen is responsible for de-duplicating once
        # auto-link fires across the per-plastic Accounts that share a line.
        ING_BANK_CODE = "1465"

        def build_account(product, kind)
          uuid = product["uuid"]
          iban = product["iban"].to_s.gsub(/\s/, "")
          iban = nil if iban.empty?
          balance_cents, balance_source = extract_balance(product, kind)

          portable_ref, portable_id =
            if kind == "liability"
              card_portable_keys(product["productNumber"])
            else
              account_portable_keys(iban)
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
              "partial_data_suspected"  => product["_partial_data_suspected"]
            }.compact
          )
        end

        # Spanish IBAN: ES kk BBBB GGGG DD CCCCCCCCCC
        # CCC bank code = bytes 4..7. ING's is always 1465; pinning it
        # explicitly keeps the portable_ref shape consistent with the
        # cards (which have no IBAN to derive the bank code from).
        def account_portable_keys(iban)
          return [nil, nil] unless iban && iban.length >= 18 && iban.start_with?("ES")
          ref = "#{ING_BANK_CODE}:#{iban[-4, 4]}"
          [ref, "bank:#{ref}"]
        end

        # Cards have no IBAN. productNumber carries the plastic's full PAN
        # (16 digits in real data, e.g. 4174804472951087); pan_last4 strips
        # it to BANKID:LAST4. Returns [nil, nil] when productNumber is
        # missing or has fewer than 4 digits — the legacy (institution,
        # source_id) derivation kicks in via Canonical.account_id.
        def card_portable_keys(product_number)
          last4 = pan_last4(product_number)
          return [nil, nil] unless last4
          ref = "#{ING_BANK_CODE}:#{last4}"
          [ref, "card:#{ref}"]
        end

        # Asset products carry a top-level numeric `balance` (the cleared
        # account balance). Credit-card products don't — ING's /products
        # payload exposes `creditLimit` and `availableBalance` for each
        # card, and the outstanding amount is the difference. Stored as a
        # NEGATIVE number to fit SimpleFIN/canonical's liability convention
        # ("you owe this much"). creditLimit/availableBalance are actually
        # line-level (shared across all plastics on the same revolving
        # line), so every plastic on a shared line emits the same balance —
        # simplefreen's per-card consolidation handles the dedup once
        # auto-link fires across them via portable_ref.
        def extract_balance(product, kind)
          if kind == "liability"
            limit     = product["creditLimit"]
            available = product["availableBalance"]
            if limit.is_a?(Numeric) && available.is_a?(Numeric)
              outstanding_cents = ((limit.to_f - available.to_f) * 100).round
              [-outstanding_cents, "ing_live:credit_limit_minus_available"]
            else
              [nil, nil]
            end
          elsif product["balance"].is_a?(Numeric)
            [(product["balance"].to_f * 100).round, "ing_live:product_balance"]
          else
            [nil, nil]
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

          date = parse_date(mv["effectiveDate"] || mv["chargeDate"],
                             preferred_formats: ING_DATE_FORMATS)
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
            status:     Builder.map_status(ing_pending_status(mv)),
            metadata:   { "ing" => extract_fields(mv, RAW_FIELDS_MOVEMENT) }
          )
        end

        def pick_name(product)
          first_present(product["alias"], product["name"]) || "ING"
        end

        def ing_pending_status(mv)
          mv.dig("status", "description") == ING_PENDING_STATUS ? "pending" : "settled"
        end

        def compact_whitespace(str)
          return nil if str.nil?
          str.to_s.gsub(/\s+/, " ").strip
        end

      end
    end
  end
end

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

          collapse_credit_lines(Array(raw)).each do |product|
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

          Builder.payload(
            accounts:     accounts,
            transactions: transactions,
            liabilities:  liabilities,
            scraper_version: SCRAPER_VERSION
          )
        end

        private

        # ING issues a separate `product` per *plastic* card, but all
        # plastics on the same revolving credit line share one balance
        # (creditLimit / availableBalance). Naively emitting one
        # canonical account per plastic counts the same debt N times in
        # downstream consumers (Sure, Actual). Collapse plastics into
        # one canonical account per credit line.
        #
        # Grouping key: (associatedAccount.uuid, creditLimit). Cards
        # without a usable associated-account uuid (defensive — should
        # be rare) fall through ungrouped so we never silently drop
        # them. The creditLimit term protects against the unlikely case
        # where associatedAccount.uuid points at a shared checking
        # account that backs multiple distinct credit lines.
        def collapse_credit_lines(products)
          liabilities, others = products.partition do |p|
            KIND_BY_PRODUCT_TYPE[p["type"].to_i] == "liability"
          end

          groups    = {}
          ungrouped = []
          liabilities.each do |p|
            line_uuid = p.dig("associatedAccount", "uuid").to_s
            limit     = p["creditLimit"]
            if line_uuid.empty? || !limit.is_a?(Numeric)
              ungrouped << p
            else
              key = [line_uuid, limit.to_f.round(2)]
              (groups[key] ||= []) << p
            end
          end

          collapsed = groups.map do |(line_uuid, limit), members|
            normalize_to_line(line_uuid, limit, members)
          end

          others + collapsed + ungrouped
        end

        # Always rewrite the source uuid to the line-uuid (even for
        # single-plastic lines) so the canonical account id is stable
        # when ING re-issues a plastic on the same revolving line.
        # Movement rollup and the diagnostic plastics breadcrumb only
        # matter when multiple plastics share the line.
        def normalize_to_line(line_uuid, limit, members)
          primary = members.first
          merged  = primary.dup
          merged["uuid"] = "ing_line_#{line_uuid}_#{limit}"
          if members.size > 1
            merged["movements"] = members.flat_map { |p| Array(p["movements"]) }
            merged["_merged_plastics"] = members.map do |p|
              {
                "uuid"          => p["uuid"],
                "productNumber" => p["productNumber"],
                "alias"         => p["alias"],
                "name"          => p["name"]
              }
            end
          end
          merged
        end


        def build_account(product, kind)
          uuid = product["uuid"]
          iban = product["iban"].to_s.gsub(/\s/, "")
          balance_cents, balance_source = extract_balance(product, kind)

          Builder.build_account(
            institution: INSTITUTION,
            source_id:   uuid,
            currency:    product["currency"] || "EUR",
            name:        pick_name(product),
            type:        kind == "liability" ? "credit_card" : "checking",
            iban:        iban.empty? ? nil : iban,
            balance:     { current: Builder.cents_to_amount(balance_cents), timestamp: nil },
            metadata: {
              "ing_product_type"     => product["type"],
              "ing_product_number"   => product["productNumber"],
              "balance_source"       => balance_source,
              "ing_merged_plastics"  => product["_merged_plastics"]
            }.compact
          )
        end

        # Asset products carry a top-level numeric `balance` (the cleared
        # account balance). Credit-card products don't — ING's
        # /products payload exposes `creditLimit` and `availableBalance`
        # for each card, and the outstanding amount is the difference.
        # We store outstanding as a NEGATIVE number so it slots into
        # SimpleFIN/canonical's liability convention ("you owe this
        # much"). Pending authorisations and aggregate fields like
        # `spentAmount` look promising but in real ING data those are
        # cardholder-wide rather than per-card — using them would
        # double-count debt across cards on a shared credit line.
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

          raw_description = mv["description"].to_s
          cleaned = (mv["description"] || mv["store"]).to_s.strip

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

      end
    end
  end
end

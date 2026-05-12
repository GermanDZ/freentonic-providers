# frozen_string_literal: true

require "date"
require "bigdecimal"
require "freentonic"

module Freentonic
  module Providers
    module Fintonic
      class Normalizer < Freentonic::Providers::NormalizerBase
        provider!(__dir__)
        # CONFIG, INSTITUTION, SCRAPER_VERSION, KIND_BY_TYPE all
        # come from fintonic/config.yml. Builder, Helpers inherited.

        def call(raw, context: {})
          category_map = build_category_map(raw["categoryTree"] || {})
          by_product = (raw["transactions"] || []).group_by do |t|
            "#{t['bankId']}_#{t['productId']}_#{t['type']}"
          end

          accounts, liabilities, transactions = [], [], []

          by_product.each_value do |txs|
            sample = txs.first
            next unless sample

            account = build_account(sample)
            accounts << account

            if KIND_BY_TYPE[sample["type"]] == "liability"
              liabilities << build_liability(sample, account)
            end

            txs.each do |tx|
              txn = build_transaction(tx, account, category_map)
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

        def build_account(sample)
          bank_id      = sample["bankId"]
          product_id   = sample["productId"]
          product_type = sample["type"] || "ACCOUNT"
          bank_name    = sample["_bank_name"] || "Bank #{bank_id}"
          kind         = KIND_BY_TYPE[product_type] || "asset"
          source_id    = "#{bank_id}:#{product_id}"
          portable_ref, portable_id = portable_keys_for(product_type, bank_id, product_id)

          Builder.build_account(
            institution: INSTITUTION,
            source_id:   source_id,
            currency:    "EUR",
            name:        "#{bank_name} #{product_type} ##{product_id}",
            type:        kind == "liability" ? "credit_card" : "checking",
            iban:        nil,
            portable_ref: portable_ref,
            portable_id:  portable_id,
            balance:     nil,
            metadata: {
              "fintonic_bank_id"    => bank_id,
              "fintonic_product_id" => product_id,
              "fintonic_type"       => product_type
            }
          )
        end

        # Cross-provider portable key for Spanish-bank products. The 4-digit
        # guard catches both the BBAN tail (accounts) and PAN last-4 (cards)
        # — the shape that a direct provider can match. Opaque hashed
        # product_ids (banks 0232, 2048, etc.) fall back to the legacy
        # (institution, source_id) derivation since they don't collide with
        # anything observable from a direct scrape. portable_id prefix
        # disambiguates account vs card matches in human-readable logs.
        def portable_keys_for(product_type, bank_id, product_id)
          return [nil, nil] unless product_id.to_s.match?(/\A\d{4}\z/)
          ref = "#{bank_id}:#{product_id}"
          prefix =
            case product_type
            when "ACCOUNT"                 then "bank"
            when "CREDITCARD", "CREDIT_CARD" then "card"
            else return [nil, nil]
            end
          [ref, "#{prefix}:#{ref}"]
        end

        def build_liability(sample, account)
          bank_id    = sample["bankId"]
          product_id = sample["productId"]
          Builder.build_liability(
            account_id: account.id,
            type:       "credit_card",
            currency:   account.currency,
            source_id:  "#{bank_id}:#{product_id}",
            metadata:   {
              "fintonic_bank_id"    => bank_id,
              "fintonic_product_id" => product_id,
              "fintonic_type"       => sample["type"]
            }
          )
        end

        def build_transaction(tx, account, category_map)
          tx_id = tx["id"]
          return nil unless tx_id

          quantity = tx["quantity"]
          return nil if quantity.nil? || quantity == 0

          # Canonical date prefers the *original* bank-side date over the
          # user-edited one. Rationale: Fintonic lets the user manually
          # reattribute a transaction to a different date inside their
          # app (`userDate`), and that's what its API returns first. But
          # cross-source matching / dedup against a direct bank
          # provider needs the bank's own posting date, otherwise the
          # same logical transaction looks like two events on different
          # dates (debugging note: Social-Security charges on the user's
          # ING checking account drifted between ISO weeks because
          # fintonic posted them on userDate and ING on effectiveDate).
          # `userDate` is preserved in metadata.fintonic.userDate for
          # any downstream consumer that wants to expose the
          # user-chosen date.
          date = parse_date(tx["operationDate"] || tx["valueDate"] || tx["userDate"])
          return nil unless date

          category_id   = resolve_category_id(tx)
          category_path = category_map[category_id] || category_id
          raw_description = tx["description"].to_s
          cleaned = compose_description(tx)

          Builder.build_transaction(
            account_id:      account.id,
            source_id:       tx_id.to_s,
            amount:          Builder.cents_to_amount(quantity.to_i),
            currency:        tx["currency"] == "EURO" ? "EUR" : (tx["currency"] || "EUR"),
            date:            date,
            description:     cleaned,
            raw_description: raw_description,
            merchant:        build_merchant(tx),
            category:        category_path,
            metadata: {
              "fintonic" => extract_fields(tx, RAW_FIELDS_TRANSACTION).merge(
                "category_path" => category_path,
                "category_id"   => category_id
              )
            }
          )
        end

        # Prefer explicit merchant_name if present. Otherwise fall back to
        # primaryDisplay — Fintonic's normalized display string — but flag
        # it as not-normalized since we didn't verify the lookup ourselves.
        def build_merchant(tx)
          explicit = tx["merchant_name"]
          return { name: explicit.to_s, normalized: true } if explicit && !explicit.to_s.strip.empty?

          display = tx["primaryDisplay"]
          return nil if display.nil? || display.to_s.strip.empty?
          { name: display.to_s, normalized: false }
        end

        def compose_description(tx)
          main = tx["description"] || tx["cleanNote"] || tx["primaryDisplay"]
          user_desc = tx["userDescription"] || tx["cleanUserDescription"]
          if user_desc && !user_desc.to_s.strip.empty?
            [main, user_desc].compact.reject { |s| s.to_s.strip.empty? }.join(" | ")
          else
            main.to_s.strip
          end
        end

        def resolve_category_id(tx)
          cats = tx.dig("categorization", "weightedCategories") || {}
          cats.keys.first
        end

        def build_category_map(tree)
          return {} unless tree.is_a?(Hash)

          map = {}
          tree.each do |id, node|
            name = node["name"] || node["shortname"] || id.to_s
            ancestors = node["ancestors"] || []
            path_parts = ancestors.reject { |a| a == "root" }.filter_map { |a| tree.dig(a, "name") }
            path_parts << name
            map[id] = path_parts.join("/")
          end
          map
        end
      end
    end
  end
end

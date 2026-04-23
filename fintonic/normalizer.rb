# frozen_string_literal: true

require "date"
require "bigdecimal"
require "freentonic"
require_relative "../lib/freentonic/providers/helpers"
require_relative "../lib/freentonic/providers/canonical_builder"
require_relative "../lib/freentonic/providers/legacy_keys"

Freentonic::Providers::LegacyKeys.register(:fintonic,
  account: {
    external_id: "fintonic:%{bank_id}:%{product_id}",
    uids:        ["fintonic-%{bank_id}-%{product_id}-%{product_type}"],
    bank_key:    "fintonic_%{bank_id}"
  },
  transaction: {
    dedup_key: "fintonic:%{tx_id}"
  }
)

module Freentonic
  module Providers
    module Fintonic
      class Normalizer < Freentonic::Normalizers::Base
        include Freentonic::Providers::Helpers
        Builder = Freentonic::Providers::CanonicalBuilder
        LegacyKeys = Freentonic::Providers::LegacyKeys

        KIND_BY_TYPE = {
          "ACCOUNT"     => "asset",
          "CREDIT_CARD" => "liability",
          "CREDITCARD"  => "liability"
        }.freeze
        INSTITUTION = "fintonic"
        SCRAPER_VERSION = "fintonic/0.2"

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

          Builder.build_account(
            institution: INSTITUTION,
            source_id:   source_id,
            currency:    "EUR",
            name:        "#{bank_name} #{product_type} ##{product_id}",
            type:        kind == "liability" ? "credit_card" : "checking",
            iban:        nil,
            balance:     nil,
            metadata: {
              "fintonic_bank_id"    => bank_id,
              "fintonic_product_id" => product_id,
              "fintonic_type"       => product_type
            },
            **LegacyKeys.account(institution: INSTITUTION,
                                 bank_id: bank_id, product_id: product_id,
                                 product_type: product_type)
          )
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

          date = parse_date(tx["userDate"] || tx["valueDate"])
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
              "fintonic" => {
                "id"              => tx_id,
                "reference"       => tx["reference"],
                "category_path"   => category_path,
                "category_id"     => category_id,
                "operationDate"   => tx["operationDate"],
                "valueDate"       => tx["valueDate"],
                "userDate"        => tx["userDate"],
                "description"     => tx["description"],
                "cleanNote"       => tx["cleanNote"],
                "userDescription" => tx["userDescription"],
                "primaryDisplay"  => tx["primaryDisplay"]
              }
            },
            **LegacyKeys.transaction(institution: INSTITUTION, tx_id: tx_id)
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

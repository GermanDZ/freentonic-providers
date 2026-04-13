# frozen_string_literal: true

# Fintonic normalizer: converts the Extractor's raw payload
# (categories + transactions) into the universal account/movement
# shape. Transactions are grouped by {bankId}_{productId}_{type}
# into separate accounts.
#
# Adapted from finanzas/fintonic_export.rb cmd_import.

require "date"
require_relative "../lib/freentonic/providers/helpers"

module Freentonic
  module Providers
    module Fintonic
      class Normalizer < Freentonic::Normalizers::Base
        include Freentonic::Providers::Helpers

        KIND_BY_TYPE = {
          "ACCOUNT"     => "asset",
          "CREDIT_CARD" => "liability",
          "CREDITCARD"  => "liability"
        }.freeze

        def call(raw, context: {})
          # categoryTree is a flat hash: {id => {name:, ancestors:, …}}
          category_tree = raw["categoryTree"] || {}
          category_map = build_category_map(category_tree)
          transactions = raw["transactions"] || []

          by_product = transactions.group_by { |t| "#{t['bankId']}_#{t['productId']}_#{t['type']}" }

          {
            "source_tag" => "fintonic_push",
            "accounts"   => by_product.filter_map { |key, txs| build_account(key, txs, category_map) }
          }
        end

        private

        def build_account(_key, txs, category_map)
          sample = txs.first
          return nil unless sample

          bank_id = sample["bankId"]
          product_id = sample["productId"]
          product_type = sample["type"] || "ACCOUNT"
          bank_name = sample["_bank_name"] || "Bank #{bank_id}"
          kind = KIND_BY_TYPE[product_type] || "asset"

          movements = txs.filter_map { |tx| build_movement(tx, category_map) }

          {
            "external_id"   => "fintonic:#{bank_id}:#{product_id}",
            "legacy_uids"   => ["fintonic-#{bank_id}-#{product_id}-#{product_type}"],
            "iban"          => nil,
            "kind"          => kind,
            "bank_key"      => "fintonic_#{bank_id}",
            "name"          => "#{bank_name} #{product_type} ##{product_id}",
            "currency"      => "EUR",
            "balance_cents" => nil,
            "metadata"      => {
              "fintonic_bank_id"    => bank_id,
              "fintonic_product_id" => product_id,
              "fintonic_type"       => product_type
            },
            "movements"     => movements
          }
        end

        def build_movement(tx, category_map)
          tx_id = tx["id"]
          return nil unless tx_id

          quantity = tx["quantity"]
          return nil if quantity.nil? || quantity == 0

          date = parse_date(tx["userDate"] || tx["valueDate"])
          return nil unless date

          description = compose_description(tx)
          category_path = resolve_category(tx, category_map)

          {
            "dedup_key"    => "fintonic:#{tx_id}",
            "date"         => date.strftime("%Y-%m-%d"),
            "amount_cents" => quantity.to_i,
            "currency"     => tx["currency"] == "EURO" ? "EUR" : (tx["currency"] || "EUR"),
            "description"  => description,
            "raw_payload"  => {
              "fintonic" => {
                "id"             => tx_id,
                "reference"      => tx["reference"],
                "category_path"  => category_path,
                "category_id"    => resolve_category_id(tx),
                "operationDate"  => tx["operationDate"],
                "valueDate"      => tx["valueDate"],
                "userDate"       => tx["userDate"],
                "description"    => tx["description"],
                "cleanNote"      => tx["cleanNote"],
                "userDescription" => tx["userDescription"],
                "primaryDisplay" => tx["primaryDisplay"]
              }
            }
          }
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

        def resolve_category(tx, category_map)
          cat_id = resolve_category_id(tx)
          category_map[cat_id] || cat_id
        end

        def build_category_map(tree)
          return {} unless tree.is_a?(Hash)

          map = {}
          tree.each do |id, node|
            name = node["name"] || node["shortname"] || id.to_s
            ancestors = node["ancestors"] || []
            # Build path from ancestor names (skip "root")
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

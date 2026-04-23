# frozen_string_literal: true

require "date"
require "bigdecimal"
require "freentonic"
require_relative "extractor"
require_relative "../lib/freentonic/providers/canonical_builder"

module Freentonic
  module Providers
    module Ing
      class Normalizer < Freentonic::Normalizers::Base
        Builder = Freentonic::Providers::CanonicalBuilder

        KIND_BY_PRODUCT_TYPE = Extractor::KIND_BY_PRODUCT_TYPE
        ING_PENDING_STATUS = "Pendiente de liquidar"
        INSTITUTION = "ing"
        SCRAPER_VERSION = "ing/0.2"

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

          Builder.payload(
            accounts:     accounts,
            transactions: transactions,
            liabilities:  liabilities,
            scraper_version: SCRAPER_VERSION
          )
        end

        private

        def build_account(product, kind)
          uuid = product["uuid"]
          iban = product["iban"].to_s.gsub(/\s/, "")
          balance_cents =
            if product["balance"].is_a?(Numeric)
              (product["balance"].to_f * 100).round
            end

          Builder.build_account(
            institution: INSTITUTION,
            source_id:   uuid,
            currency:    product["currency"] || "EUR",
            name:        pick_name(product),
            type:        kind == "liability" ? "credit_card" : "checking",
            iban:        iban.empty? ? nil : iban,
            balance:     { current: Builder.cents_to_amount(balance_cents), timestamp: nil },
            metadata: {
              "ing_product_type"   => product["type"],
              "ing_product_number" => product["productNumber"],
              "balance_source"     => balance_cents ? "ing_live:product_balance" : nil
            },
            legacy_external_id: "ing_live:#{uuid}",
            legacy_uids:        legacy_account_uids(kind, uuid),
            legacy_bank_key:    kind == "liability" ? "ing_cc" : "ing"
          )
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

        def build_transaction(product, account, mv)
          mv_uuid = mv["uuid"]
          return nil unless mv_uuid

          amount = mv["amount"]
          return nil unless amount.is_a?(Numeric) && amount != 0

          date = parse_ing_date(mv["effectiveDate"] || mv["chargeDate"])
          return nil unless date

          raw_description = mv["description"].to_s
          cleaned = (mv["description"] || mv["store"]).to_s.strip

          Builder.build_transaction(
            account_id: account.id,
            source_id:  mv_uuid,
            amount:     amount,
            currency:   mv["currency"] || "EUR",
            date:       date,
            value_date: parse_ing_date(mv["clearingDate"]),
            description:     cleaned,
            raw_description: raw_description,
            status:     Builder.map_status(ing_pending_status(mv)),
            metadata:   { "ing" => build_raw_fields(mv) },
            legacy_dedup_key: "ing_live:#{product["uuid"]}:#{mv_uuid}"
          )
        end

        def pick_name(product)
          alias_name = product["alias"].to_s.strip
          alias_name.empty? ? (product["name"] || "ING") : alias_name
        end

        def legacy_account_uids(kind, uuid)
          base = ["ing_live:#{uuid}"]
          kind == "liability" ? ["ing-cc-#{uuid}"] + base : base
        end

        def ing_pending_status(mv)
          mv.dig("status", "description") == ING_PENDING_STATUS ? "pending" : "settled"
        end

        def build_raw_fields(mv)
          {
            "uuid"               => mv["uuid"],
            "operationId"        => mv["operationId"],
            "status"             => mv.dig("status", "description"),
            "tranCode"           => mv["tranCode"],
            "typeCod"            => mv["typeCod"],
            "typeDesc"           => mv["typeDesc"],
            "store"              => mv["store"],
            "description"        => mv["description"],
            "effectiveDate"      => mv["effectiveDate"],
            "chargeDate"         => mv["chargeDate"],
            "clearingDate"       => mv["clearingDate"],
            "clearanceStartDate" => mv["clearanceStartDate"],
            "clearanceEndDate"   => mv["clearanceEndDate"],
            "cardNumber"         => mv["cardNumber"],
            "opCountry"          => mv["opCountry"],
            "opHour"             => mv["opHour"],
            "ecommerce"          => mv["ecommerce"],
            "originAmount"       => mv["originAmount"],
            "amount"             => mv["amount"]
          }
        end

        def parse_ing_date(str)
          return nil if str.to_s.empty?
          Date.strptime(str, "%d/%m/%Y")
        rescue Date::Error
          begin
            Date.parse(str)
          rescue
            nil
          end
        end
      end
    end
  end
end

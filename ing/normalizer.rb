# frozen_string_literal: true

require "date"
require "bigdecimal"
require "freentonic"
require_relative "extractor"
Freentonic::Providers::LegacyKeysLoader.load_provider!(__dir__)

module Freentonic
  module Providers
    module Ing
      class Normalizer < Freentonic::Normalizers::Base
        include Freentonic::Providers::Helpers
        Builder = Freentonic::Providers::CanonicalBuilder
        LegacyKeys = Freentonic::Providers::LegacyKeys

        # Spanish-format dates dominate ING's feed; hint the helper so
        # Date.parse doesn't flip DD/MM for months ≤ 12.
        ING_DATE_FORMATS = ["%d/%m/%Y"].freeze

        # Provider knobs from ing/config.yml; the Extractor's load_provider!
        # call has already populated the cache by the time this file loads.
        CONFIG               = Freentonic::Providers::Config.for(:ing)
        INSTITUTION          = CONFIG.fetch(:institution)
        SCRAPER_VERSION      = CONFIG.fetch(:scraper_version)
        KIND_BY_PRODUCT_TYPE = CONFIG.fetch(:kind_by_product_type)

        ING_PENDING_STATUS = "Pendiente de liquidar"

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
            **LegacyKeys.account(institution: INSTITUTION, source_id: uuid, kind: kind)
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
            metadata:   { "ing" => build_raw_fields(mv) },
            **LegacyKeys.transaction(institution: INSTITUTION,
                                     account_source_id: product["uuid"],
                                     tx_source_id: mv_uuid)
          )
        end

        def pick_name(product)
          alias_name = product["alias"].to_s.strip
          alias_name.empty? ? (product["name"] || "ING") : alias_name
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

      end
    end
  end
end

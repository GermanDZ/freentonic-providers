# frozen_string_literal: true

# ING normalizer: converts the Extractor's raw product/movement payload
# into the universal account/movement shape that freentonic HTTP receivers
# are expected to accept (source_tag, accounts[].movements[]). The exact
# receiver spec is defined by the ingest system you export to.

require "date"
require_relative "extractor"

module Freentonic
  module Providers
    module Ing
      class Normalizer < Freentonic::Normalizers::Base
        KIND_BY_PRODUCT_TYPE = Extractor::KIND_BY_PRODUCT_TYPE
        ING_PENDING_STATUS = "Pendiente de liquidar"

        def call(raw, context: {})
          {
            "source_tag" => "ing_push",
            "accounts"   => Array(raw).filter_map { |p| build_account(p) }
          }
        end

        private

        def build_account(product)
          type_id = product["type"].to_i
          kind = KIND_BY_PRODUCT_TYPE[type_id]
          return nil if kind.nil?

          uuid = product["uuid"]
          legacy_uids = ["ing_live:#{uuid}"]
          legacy_uids.unshift("ing-cc-#{uuid}") if kind == "liability"

          iban = product["iban"].to_s.gsub(/\s/, "")

          balance_cents = if product["balance"].is_a?(Numeric)
                            (product["balance"].to_f * 100).round
                          end

          movements = (product["movements"] || []).filter_map { |mv| build_movement(uuid, mv) }

          {
            "external_id"    => "ing_live:#{uuid}",
            "legacy_uids"    => legacy_uids,
            "iban"           => iban.empty? ? nil : iban,
            "product_number" => product["productNumber"],
            "kind"           => kind,
            "bank_key"       => kind == "liability" ? "ing_cc" : "ing",
            "name"           => product["alias"].to_s.strip.empty? ? (product["name"] || "ING") : product["alias"],
            "currency"       => product["currency"] || "EUR",
            "balance_cents"  => balance_cents,
            "balance_source" => balance_cents ? "ing_live:product_balance" : nil,
            "metadata"       => {
              "ing_product_type"   => product["type"],
              "ing_product_number" => product["productNumber"]
            },
            "movements"      => movements
          }
        end

        def build_movement(product_uuid, mv)
          mv_uuid = mv["uuid"]
          return nil unless mv_uuid

          amount = mv["amount"]
          return nil unless amount.is_a?(Numeric) && amount != 0

          date_str = mv["effectiveDate"] || mv["chargeDate"]
          date = parse_ing_date(date_str)
          return nil unless date

          status_desc = mv.dig("status", "description")
          pending_status = (status_desc == ING_PENDING_STATUS) ? "pending" : "settled"

          {
            "dedup_key"      => "ing_live:#{product_uuid}:#{mv_uuid}",
            "date"           => date.strftime("%Y-%m-%d"),
            "amount_cents"   => (amount * 100).round,
            "currency"       => mv["currency"] || "EUR",
            "description"    => (mv["description"] || mv["store"]).to_s.strip,
            "pending_status" => pending_status,
            "raw_payload"    => { "ing" => build_raw_fields(mv) }
          }
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

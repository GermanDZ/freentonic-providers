# frozen_string_literal: true

require "date"
require "bigdecimal"
require "freentonic"
require_relative "../lib/freentonic/providers/canonical_builder"
require_relative "../lib/freentonic/providers/legacy_keys"

Freentonic::Providers::LegacyKeys.register(:revolut,
  account: {
    external_id: "revolut_live:%{kind}:%{source_ref}",
    uids:        ["revolut_live:%{kind}:%{source_ref}"],
    bank_key: {
      default:  "revolut",
      if_vault: "revolut_vault"
    }
  },
  transaction: {
    dedup_key: "revolut_live:%{pocket_id}:%{tx_id}"
  }
)

module Freentonic
  module Providers
    module Revolut
      class Normalizer < Freentonic::Normalizers::Base
        Builder = Freentonic::Providers::CanonicalBuilder
        LegacyKeys = Freentonic::Providers::LegacyKeys

        INSTITUTION = "revolut"
        SCRAPER_VERSION = "revolut/0.2"

        def call(raw, context: {})
          accounts, transactions = [], []

          Array(raw["pockets"]).each do |pocket|
            account = build_pocket_account(pocket, raw["bank_details"] || [])
            next unless account
            accounts << account

            (raw["pocket_transactions"]&.[](pocket["id"]) || []).each do |tx|
              txn = build_transaction(pocket, account, tx)
              transactions << txn if txn
            end
          end

          Array(raw["vaults"]).each do |vault|
            account = build_vault_account(vault)
            accounts << account if account
          end

          Builder.payload(
            accounts:     accounts,
            transactions: transactions,
            scraper_version: SCRAPER_VERSION
          )
        end

        private

        # --- Pockets ---------------------------------------------------------

        def build_pocket_account(pocket, bank_details)
          pocket_id = pocket["id"]
          return nil unless pocket_id

          currency = pocket["currency"] || "EUR"
          Builder.build_account(
            institution: INSTITUTION,
            source_id:   "pocket:#{pocket_id}",
            currency:    currency,
            name:        pocket["name"] || "Revolut #{currency}",
            type:        "checking",
            iban:        find_iban(pocket, bank_details),
            balance:     { current: Builder.cents_to_amount(cents(pocket["balance"])), timestamp: nil },
            metadata: {
              "revolut_pocket_id" => pocket_id,
              "revolut_type"      => pocket["type"],
              "balance_source"    => "revolut_live:wallet"
            },
            **LegacyKeys.account(institution: INSTITUTION, kind: "pocket", source_ref: pocket_id)
          )
        end

        # --- Vaults (savings) -----------------------------------------------

        def build_vault_account(vault)
          vault_id = vault["id"]
          return nil unless vault_id

          currency = vault["currency"] || "EUR"
          balance_cents = cents(vault["balance"] || vault["currentAmount"])

          Builder.build_account(
            institution: INSTITUTION,
            source_id:   "vault:#{vault_id}",
            currency:    currency,
            name:        vault["name"] || "Revolut Vault",
            type:        "savings",
            iban:        nil,
            balance:     { current: Builder.cents_to_amount(balance_cents), timestamp: nil },
            metadata: {
              "revolut_vault_id" => vault_id,
              "revolut_goal"     => vault["goal"],
              "balance_source"   => "revolut_live:vault"
            },
            **LegacyKeys.account(institution: INSTITUTION, kind: "vault", source_ref: vault_id)
          )
        end

        # --- Transactions ---------------------------------------------------

        def build_transaction(pocket, account, tx)
          tx_id = tx["id"] || tx["legId"]
          return nil unless tx_id

          amount_cents = extract_amount_cents(tx)
          return nil unless amount_cents && amount_cents != 0

          date = parse_revolut_date(tx["startedDate"] || tx["completedDate"] || tx["createdDate"])
          return nil unless date

          raw_description = tx["description"].to_s
          cleaned = build_description(tx)

          Builder.build_transaction(
            account_id:      account.id,
            source_id:       tx_id.to_s,
            amount:          Builder.cents_to_amount(amount_cents),
            currency:        tx["currency"] || pocket["currency"] || "EUR",
            date:            date,
            description:     cleaned,
            raw_description: raw_description,
            merchant:        build_merchant(tx),
            metadata:        { "revolut" => tx },
            **LegacyKeys.transaction(institution: INSTITUTION,
                                     pocket_id: pocket["id"], tx_id: tx_id)
          )
        end

        def build_merchant(tx)
          m = tx["merchant"]
          return nil unless m.is_a?(Hash)
          name = m["name"]
          return nil if name.nil? || name.to_s.strip.empty?
          { name: name.to_s, normalized: true }
        end

        # --- Helpers --------------------------------------------------------

        def build_description(tx)
          desc = tx["description"] || tx.dig("merchant", "name") || tx["type"]
          desc.to_s.strip
        end

        def extract_amount_cents(tx)
          amount = tx["amount"] || tx["legs"]&.first&.dig("amount")
          cents(amount)
        end

        # Revolut pocket balances and transaction amounts are already in
        # minor units (cents). Vault balances are in major units inside
        # a Hash like {"amount" => 12.34, "currency" => "EUR"}.
        def cents(amount)
          return nil if amount.nil?

          case amount
          when Hash
            value = (amount["amount"] || amount["value"])&.to_f
            value ? (value * 100).round : nil
          when Numeric
            amount.to_i
          when String
            (amount.tr(",", ".").to_f * 100).round
          end
        end

        def find_iban(pocket, bank_details)
          return nil unless bank_details.is_a?(Array)

          entry = bank_details.find { |d| d["currency"] == pocket["currency"] }
          return nil unless entry

          accounts = entry.dig("details", "accounts")
          return nil unless accounts.is_a?(Array)

          account = accounts.find { |a| a["iban"] }
          account&.dig("iban")
        end

        def parse_revolut_date(value)
          return nil if value.nil?

          case value
          when Numeric
            Time.at(value / 1000.0).to_date
          when String
            if value =~ /\A\d+\z/
              Time.at(value.to_i / 1000.0).to_date
            else
              Date.parse(value)
            end
          end
        rescue ArgumentError, TypeError
          nil
        end
      end
    end
  end
end

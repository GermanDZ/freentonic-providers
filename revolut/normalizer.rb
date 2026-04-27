# frozen_string_literal: true

require "date"
require "bigdecimal"
require "freentonic"

module Freentonic
  module Providers
    module Revolut
      class Normalizer < Freentonic::Providers::NormalizerBase
        provider!(__dir__)
        # CONFIG, INSTITUTION, SCRAPER_VERSION come from revolut/config.yml.
        # Builder, Helpers inherited.

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
          parent_iban = find_iban(pocket, bank_details)
          # Revolut pockets are virtual sub-accounts of the user's main
          # wallet — every EUR pocket shares the same IBAN. Surfacing
          # that IBAN at the canonical Account level makes
          # Canonical.account_id collide across pockets (its ref priority
          # picks IBAN over source_id), collapsing every EUR pocket onto
          # one canonical id and clobbering balances downstream. Keep the
          # parent IBAN in metadata only; let source_id drive the id.
          Builder.build_account(
            institution: INSTITUTION,
            source_id:   "pocket:#{pocket_id}",
            currency:    currency,
            name:        pocket["name"] || "Revolut #{currency}",
            type:        "checking",
            iban:        nil,
            balance:     { current: Builder.cents_to_amount(cents(pocket["balance"], already_minor: true)), timestamp: nil },
            metadata: {
              "revolut_pocket_id"   => pocket_id,
              "revolut_type"        => pocket["type"],
              "revolut_parent_iban" => parent_iban,
              "balance_source"      => "revolut_live:wallet"
            }.compact
          )
        end

        # --- Vaults (savings) -----------------------------------------------

        def build_vault_account(vault)
          vault_id = vault["id"]
          return nil unless vault_id

          currency = vault["currency"] || "EUR"
          balance_cents = cents(vault["balance"] || vault["currentAmount"], already_minor: true)

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
            }
          )
        end

        # --- Transactions ---------------------------------------------------

        def build_transaction(pocket, account, tx)
          tx_id = tx["id"] || tx["legId"]
          return nil unless tx_id

          amount_cents = extract_amount_cents(tx)
          return nil unless amount_cents && amount_cents != 0

          date = parse_date(tx["startedDate"] || tx["completedDate"] || tx["createdDate"])
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
            metadata:        { "revolut" => tx }
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
          cents(amount, already_minor: true)
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

      end
    end
  end
end

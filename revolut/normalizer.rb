require "date"

module Freentonic
  module Providers
    module Revolut
      class Normalizer < Freentonic::Normalizers::Base
        def call(raw, context: {})
          accounts = []
          accounts.concat(build_pocket_accounts(raw))
          accounts.concat(build_vault_accounts(raw))

          {
            "source_tag" => "revolut_push",
            "accounts"   => accounts
          }
        end

        private

        # --- Pockets (main currency wallets) ---

        def build_pocket_accounts(raw)
          pockets      = raw["pockets"] || []
          bank_details = raw["bank_details"] || []
          transactions = raw["pocket_transactions"] || {}

          pockets.filter_map do |pocket|
            build_pocket_account(pocket, bank_details, transactions[pocket["id"]] || [])
          end
        end

        def build_pocket_account(pocket, bank_details, txns)
          pocket_id = pocket["id"]
          return nil unless pocket_id

          {
            "external_id"    => "revolut_live:pocket:#{pocket_id}",
            "legacy_uids"    => ["revolut_live:pocket:#{pocket_id}"],
            "iban"           => find_iban(pocket, bank_details),
            "kind"           => "asset",
            "bank_key"       => "revolut",
            "name"           => pocket["name"] || "Revolut #{pocket['currency']}",
            "currency"       => pocket["currency"] || "EUR",
            "balance_cents"  => cents(pocket["balance"]),
            "balance_source" => "revolut_live:wallet",
            "metadata"       => {
              "revolut_pocket_id" => pocket_id,
              "revolut_type"      => pocket["type"]
            },
            "movements"      => txns.filter_map { |tx| build_movement(pocket_id, tx) }
          }
        end

        # --- Vaults / savings ---

        def build_vault_accounts(raw)
          vaults = raw["vaults"] || []
          vaults.filter_map { |v| build_vault_account(v) }
        end

        def build_vault_account(vault)
          vault_id = vault["id"]
          return nil unless vault_id

          {
            "external_id"    => "revolut_live:vault:#{vault_id}",
            "legacy_uids"    => ["revolut_live:vault:#{vault_id}"],
            "iban"           => nil,
            "kind"           => "asset",
            "bank_key"       => "revolut_vault",
            "name"           => vault["name"] || "Revolut Vault",
            "currency"       => vault["currency"] || "EUR",
            "balance_cents"  => cents(vault["balance"] || vault["currentAmount"]),
            "balance_source" => "revolut_live:vault",
            "metadata"       => {
              "revolut_vault_id" => vault_id,
              "revolut_goal"     => vault["goal"]
            },
            "movements"      => []
          }
        end

        # --- Movements ---

        def build_movement(pocket_id, tx)
          tx_id = tx["id"] || tx["legId"]
          return nil unless tx_id

          amount = extract_amount_cents(tx)
          return nil unless amount && amount != 0

          date = parse_revolut_date(tx["startedDate"] || tx["completedDate"] || tx["createdDate"])
          return nil unless date

          {
            "dedup_key"    => "revolut_live:#{pocket_id}:#{tx_id}",
            "date"         => date.strftime("%Y-%m-%d"),
            "amount_cents" => amount,
            "currency"     => tx["currency"] || "EUR",
            "description"  => build_description(tx),
            "raw_payload"  => { "revolut_transaction" => tx }
          }
        end

        # --- Helpers ---

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
          return nil if bank_details.nil? || !bank_details.is_a?(Array)

          entry = bank_details.find { |d| d["currency"] == pocket["currency"] }
          return nil unless entry

          # Structure: { "details" => { "accounts" => [{ "iban" => "..." }] } }
          accounts = entry.dig("details", "accounts")
          return nil unless accounts.is_a?(Array)

          account = accounts.find { |a| a["iban"] }
          account&.dig("iban")
        end

        def parse_revolut_date(value)
          return nil if value.nil?

          case value
          when Numeric
            # Unix timestamp in milliseconds
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

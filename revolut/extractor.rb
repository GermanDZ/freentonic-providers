require "freentonic"

module Freentonic
  module Providers
    module Revolut
      class Extractor < Freentonic::Providers::ExtractorBase
        provider!(__dir__)

        def call(client:, credentials:, from_date:, stdout:, stderr:)
          from_ms = from_date.to_time.to_i * 1000

          # 1. Wallet — the primary account structure with pockets
          stdout.puts "  Fetching wallet..."
          wallet = client.fetch_wallet
          pockets = wallet.is_a?(Hash) ? (wallet["pockets"] || []) : []
          stdout.puts "    → #{pockets.size} pockets"

          # 2. Bank account details (IBANs) — one request per currency
          stdout.puts "  Fetching bank account details..."
          bank_details = []
          currencies = pockets.map { |p| p["currency"] }.compact.uniq
          currencies.each do |currency|
            detail = safe_fetch(stderr, "bank details (#{currency})") {
              client.fetch_bank_details(currency: currency)
            }
            bank_details << { "currency" => currency, "details" => detail } if detail
          end
          stdout.puts "    → #{bank_details.size} currency details"

          # 3. Cards
          stdout.puts "  Fetching cards..."
          cards = safe_fetch(stderr, "cards") { client.fetch_cards }
          stdout.puts "    → #{Array(cards).size} cards"

          # 4. Vaults / savings
          stdout.puts "  Fetching vaults..."
          vaults = safe_fetch(stderr, "vaults") { client.fetch_vaults }
          stdout.puts "    → #{Array(vaults).size} vaults"

          # 5. Transactions per pocket. Pagination (initial cursor = now,
          # cursor extracted from last row's timestamp, stop on from_ms
          # crossing) is declared on fetch_pocket_transactions in
          # workflow.yml — one call returns all rows for the pocket.
          pocket_transactions = {}
          pockets.each do |pocket|
            pocket_id = pocket["id"]
            label = pocket["name"] || pocket["currency"] || pocket_id
            stdout.puts "  Fetching transactions for #{label}..."
            txns = safe_fetch(stderr, "transactions (#{label})") {
              client.fetch_pocket_transactions(pocket_id: pocket_id, from_ms: from_ms)
            } || []
            pocket_transactions[pocket_id] = txns
            stdout.puts "    → #{txns.size} transactions"
          end

          {
            "wallet"              => wallet,
            "pockets"             => pockets,
            "bank_details"        => bank_details,
            "cards"               => cards,
            "vaults"              => vaults,
            "pocket_transactions" => pocket_transactions
          }
        end
      end
    end
  end
end

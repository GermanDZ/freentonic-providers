require "freentonic"

module Freentonic
  module Providers
    module Revolut
      class Extractor < Freentonic::Providers::ExtractorBase
        provider!(__dir__)

        MAX_TRANSACTIONS_SAFETY_CAP = 10_000
        PAGE_SIZE = 50

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

          # 5. Transactions per pocket
          pocket_transactions = {}
          pockets.each do |pocket|
            pocket_id = pocket["id"]
            label = pocket["name"] || pocket["currency"] || pocket_id
            stdout.puts "  Fetching transactions for #{label}..."
            begin
              txns = fetch_all_transactions(client, pocket_id, from_ms, stdout)
              pocket_transactions[pocket_id] = txns
              stdout.puts "    → #{txns.size} transactions"
            rescue StandardError => error
              stderr.puts "    ✗ #{error.class}: #{error.message}"
              pocket_transactions[pocket_id] = []
            end
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

        private

        def fetch_all_transactions(client, pocket_id, from_ms, stdout)
          all = []
          # Start from now, paginate backward in time
          to_timestamp = (Time.now.to_f * 1000).to_i

          loop do
            page = client.fetch_transactions_page(
              pocket_id: pocket_id,
              to: to_timestamp.to_s
            )
            transactions = case page
                           when Array then page
                           when Hash  then page["transactions"] || page["items"] || []
                           else []
                           end

            break if transactions.empty?

            all.concat(transactions)

            break if all.size >= MAX_TRANSACTIONS_SAFETY_CAP

            # Cursor: timestamp of the last transaction, moving backward
            last_ts = last_timestamp(transactions.last)
            break if last_ts.nil?

            next_to = last_ts.is_a?(Numeric) ? last_ts : parse_timestamp_ms(last_ts)
            break if next_to.nil?
            break if next_to >= to_timestamp
            break if next_to <= from_ms

            to_timestamp = next_to
          end

          all
        end

        def last_timestamp(tx)
          return nil unless tx.is_a?(Hash)
          tx["startedDate"] || tx["completedDate"] || tx["createdDate"]
        end
      end
    end
  end
end

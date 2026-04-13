# frozen_string_literal: true

# Fintonic extractor: fetches the category tree and all transactions
# via the Fintonic REST API. Uses /transaction/list which returns
# transactions across all linked banks in a single response.
#
# Adapted from finanzas/fintonic_export.rb cmd_export + fetch_all_transactions.

require_relative "../lib/freentonic/providers/helpers"

module Freentonic
  module Providers
    module Fintonic
      class Extractor
        include Freentonic::Providers::Helpers

        PAGE_LIMIT = 100

        def call(client:, credentials:, from_date:, stdout:, stderr:)
          # 1. Date range — determines begin_date and end_date for pagination.
          date_range = safe_fetch(stderr, "date range") { client.fetch_date_range }
          end_date = date_range&.dig("newerTransactionUserDate") || Date.today.strftime("%Y-%m-%d")
          begin_date = from_date&.strftime("%Y-%m-%d") || date_range&.dig("olderTransactionUserDate") || "2015-01-01"
          stdout.puts "  Date range: #{begin_date} → #{end_date}"

          # 2. Category tree — response is {"categoryTree": {id: {…}, …}}.
          raw_categories = safe_fetch(stderr, "categories") { client.fetch_categories }
          category_map = raw_categories&.dig("categoryTree") || {}
          stdout.puts "  Categories: #{category_map.size} entries"

          # 3. Fetch all transactions (all banks in one endpoint).
          all_transactions = fetch_all_transactions(client, begin_date, end_date, stdout, stderr)

          # Tag each transaction with its bank name for the normalizer.
          bank_names = all_transactions.map { |t| t["bankId"] }.uniq
          stdout.puts "  Banks found: #{bank_names.join(', ')}"

          stdout.puts "  Total: #{all_transactions.size} transactions"

          { "categoryTree" => category_map, "transactions" => all_transactions }
        end

        private

        def fetch_all_transactions(client, begin_date, end_date, stdout, stderr)
          txs = []

          # Read transactions — paginated.
          offset = 0
          total = nil
          loop do
            result = client.fetch_transactions(
              page_limit: PAGE_LIMIT, page_offset: offset,
              begin_date: begin_date, end_date: end_date, read_flag: "true"
            )
            total ||= result["count"]
            batch = result["resultList"] || []
            stdout.puts "    Read page offset=#{offset}: #{batch.size} transactions (total: #{total})"
            break if batch.empty?

            txs.concat(batch)
            offset += PAGE_LIMIT
            break if total && txs.size >= total

            sleep(0.3)
          end

          # Unread transactions — single request.
          begin
            unread = client.fetch_transactions(
              page_limit: -1, page_offset: 0,
              begin_date: begin_date, end_date: end_date, read_flag: "false"
            )
            unread_txs = unread["resultList"] || []
            existing_ids = txs.map { |t| t["id"] }.to_set
            new_unread = unread_txs.reject { |t| existing_ids.include?(t["id"]) }
            txs.concat(new_unread)
            stdout.puts "    Unread: #{unread_txs.size} total, #{new_unread.size} new"
          rescue StandardError => error
            stderr.puts "    ✗ Unread fetch failed: #{error.class}: #{error.message}"
          end

          # Deduplicate by Fintonic transaction ID.
          before = txs.size
          txs.uniq! { |t| t["id"] }
          dupes = before - txs.size
          stdout.puts "  Deduplicated: removed #{dupes}" if dupes > 0

          txs
        end
      end
    end
  end
end

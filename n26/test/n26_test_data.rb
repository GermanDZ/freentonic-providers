# frozen_string_literal: true

# Synthetic N26 GraphQL response shapes, hand-built from the field names the
# web app's spacesForOverview / getSpaceTransactions responses carry. No real
# data: ids, IBANs, names and amounts are invented.
module N26TestData
  PRIMARY_ID = "11111111-1111-4111-8111-111111111111"
  SAVINGS_ID = "22222222-2222-4222-8222-222222222222"

  module_function

  def space(id:, name:, primary:, balance:, iban:)
    {
      "id" => id, "accountId" => "acct-#{id[0, 4]}", "accountType" => primary ? "PRIMARY" : "SPACE",
      "name" => name, "isPrimary" => primary, "type" => "REGULAR",
      "balance" => { "availableBalance" => balance, "overdraftAmount" => nil, "currency" => "EUR" },
      "externalIds" => [{ "bic" => "NTSBDEB1XXX", "type" => "IBAN", "value" => iban }]
    }
  end

  def spaces_overview
    {
      "spaces" => {
        "overview" => {
          "items" => [
            space(id: PRIMARY_ID, name: "Main Account", primary: true, balance: 1234.56,
                  iban: "ES0015000000000000001234"),
            space(id: SAVINGS_ID, name: "Savings", primary: false, balance: 500.0,
                  iban: "ES0015000000000000005678")
          ]
        }
      }
    }
  end

  def tx(id:, title:, amount:, timestamp:, style: "NONE", reference: nil)
    {
      "externalId" => id, "title" => title, "amount" => amount, "currency" => "EUR",
      "amountStyle" => style, "type" => "TRANSACTION", "timestamp" => timestamp,
      "category" => "micro-v2-food-groceries", "spaceId" => nil, "customReferenceText" => reference,
      "balance" => { "amount" => 0.0, "currency" => "EUR" }
    }
  end

  # The timeline interleaves month/day headers with transactions; only
  # TRANSACTION items are real postings.
  def primary_timeline
    {
      "timeline" => {
        "balance" => { "amount" => 1234.56, "currency" => "EUR" },
        "modules" => [{
          "paginationKey" => "page-2",
          "timelineItems" => [
            { "type" => "TRANSACTION_YEAR", "title" => "March 2024", "timestamp" => nil },
            { "type" => "TRANSACTION_GROUP", "title" => "Friday 15 March", "timestamp" => 1_710_504_000_000 },
            tx(id: "aaaaaaaa-0000-4000-8000-000000000001", title: "Coffee Shop", amount: -12.34,
               timestamp: 1_710_504_000_000),
            tx(id: "aaaaaaaa-0000-4000-8000-000000000002", title: "Salary", amount: 2500.0,
               timestamp: 1_710_417_600_000),
            tx(id: "aaaaaaaa-0000-4000-8000-000000000003", title: "Refunded Order", amount: -40.0,
               timestamp: 1_710_331_200_000, style: "STRIKETHROUGH")
          ]
        }]
      }
    }
  end

  # getSpace: names the Space whose detail page (and timeline) was opened.
  def space_detail(id = PRIMARY_ID)
    { "spaceDetails" => { "id" => id, "name" => "Main Account" } }
  end

  # getSpaceTimeline: one "Load more" page (no modules wrapper).
  def older_page(*txs)
    {
      "timeline" => {
        "paginationKey" => "next",
        "timelineItems" => [{ "type" => "TRANSACTION_GROUP", "title" => "Monday 1 January", "timestamp" => 0 }, *txs]
      }
    }
  end

  # A first page with several modules — the timeline can split its items
  # across modules, and every one counts.
  def timeline_with_modules(*module_items)
    {
      "timeline" => {
        "modules" => module_items.map { |items| { "paginationKey" => nil, "timelineItems" => items } }
      }
    }
  end

  # Two older pages; the boundary repeats one posting (…0005) to exercise
  # the dedup across pages.
  def timeline_pages
    [
      older_page(
        tx(id: "aaaaaaaa-0000-4000-8000-000000000004", title: "Bookshop", amount: -20.0, timestamp: 1_704_103_200_000),
        tx(id: "aaaaaaaa-0000-4000-8000-000000000005", title: "Rent", amount: -800.0, timestamp: 1_704_016_800_000)
      ),
      older_page(
        tx(id: "aaaaaaaa-0000-4000-8000-000000000005", title: "Rent", amount: -800.0, timestamp: 1_704_016_800_000),
        tx(id: "aaaaaaaa-0000-4000-8000-000000000006", title: "Refund", amount: 15.5, timestamp: 1_703_930_400_000)
      )
    ]
  end

  # The workflow context as the connect phase leaves it. `pages` defaults to
  # [] — what capture_response_json all: true / required: false stores when
  # the first page was enough.
  def captured_context(overview: spaces_overview, timeline: primary_timeline, detail: space_detail, pages: [])
    { "spaces_overview" => overview, "space_timeline" => timeline, "space_detail" => detail,
      "space_timeline_pages" => pages }
  end
end

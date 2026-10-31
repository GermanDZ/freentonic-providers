# frozen_string_literal: true

require "minitest/autorun"
require "bigdecimal"
require "stringio"
require "date"
require "freentonic"
require_relative "n26_test_data"
require_relative "n26_harness"

# Runs the declarative normalize plan exactly as a live sync builds it, fed
# by the extract plan's output for synthetic captured responses.
class N26NormalizerTest < Minitest::Test
  def raw(context = N26TestData.captured_context) = N26Harness.extract(context)

  def normalize(raw_payload) = N26Harness.normalize(raw_payload)

  def payload
    @payload ||= normalize(raw)
  end

  def test_older_pages_become_transactions_of_the_same_account
    paged = normalize(raw(N26TestData.captured_context(pages: N26TestData.timeline_pages)))
    primary_id = paged.accounts.find { |a| a.source_id == "space:#{N26TestData::PRIMARY_ID}" }.id

    assert_equal 6, paged.transactions.size
    assert_equal [primary_id], paged.transactions.map(&:account_id).uniq
    assert_equal 6, paged.transactions.map(&:id).uniq.size
    refund = paged.transactions.find { |t| t.description == "Refund" }
    assert_equal BigDecimal("15.50"), refund.amount
  end

  def primary
    payload.accounts.find { |a| a.source_id == "space:#{N26TestData::PRIMARY_ID}" }
  end

  def savings
    payload.accounts.find { |a| a.source_id == "space:#{N26TestData::SAVINGS_ID}" }
  end

  def test_one_account_per_space
    assert_kind_of Freentonic::Canonical::CanonicalPayload, payload
    assert_equal "n26/0.1", payload.meta["scraper_version"]
    assert_equal 2, payload.accounts.size
    assert_equal 2, payload.accounts.map(&:id).uniq.size, "each Space gets a distinct canonical id"
  end

  def test_primary_space_is_checking_with_iban
    assert_equal "n26", primary.institution
    assert_equal "checking", primary.type
    assert_equal "Main Account", primary.name
    assert_equal "ES0015000000000000001234", primary.iban
    assert_equal BigDecimal("1234.56"), primary.balance.current
  end

  def test_other_space_is_savings_with_iban_in_metadata_only
    assert_equal "savings", savings.type
    assert_nil savings.iban, "only the primary Space surfaces its IBAN"
    assert_equal "ES0015000000000000005678", savings.metadata["n26_iban"]
    assert_equal BigDecimal("500.00"), savings.balance.current
  end

  def test_transactions_attach_to_the_primary_space
    assert_equal 3, payload.transactions.size
    assert_equal [primary.id], payload.transactions.map(&:account_id).uniq

    coffee = payload.transactions.find { |t| t.description == "Coffee Shop" }
    assert_equal BigDecimal("-12.34"), coffee.amount
    assert_equal "aaaaaaaa-0000-4000-8000-000000000001", coffee.source_id
    assert_equal "posted", coffee.status
    assert_equal "micro-v2-food-groceries", coffee.category
  end

  # 1_710_504_000_000 ms = 2024-03-15 12:00 UTC → booked on the 15th.
  # 1_710_417_600_000 ms = 2024-03-14 12:00 UTC → the 14th.
  def test_dates_are_madrid_calendar_days
    by_title = payload.transactions.to_h { |t| [t.description, t.date] }
    assert_equal Date.new(2024, 3, 15), by_title["Coffee Shop"]
    assert_equal Date.new(2024, 3, 14), by_title["Salary"]
  end

  # 2024-03-15 23:30 UTC is already the 16th in Madrid (UTC+1) — booked by
  # the Madrid day whatever zone the sync runs in.
  def test_a_near_midnight_posting_books_on_the_madrid_day
    late = N26TestData.tx(id: "late", title: "Late", amount: -5.0, timestamp: 1_710_545_400_000)
    paid = normalize(raw(N26TestData.captured_context(timeline: N26TestData.timeline_with_modules([late]))))

    assert_equal Date.new(2024, 3, 16), paid.transactions.first.date
  end

  # A transfer's reference is often all that tells two transfers from the
  # same person apart, so it joins the title in the description.
  def test_a_transfer_reference_joins_the_description
    transfer = N26TestData.tx(id: "tr", title: " Alex Example ", amount: 20.0, timestamp: 1_710_504_000_000,
                              reference: " Dinner ")
    paid = normalize(raw(N26TestData.captured_context(timeline: N26TestData.timeline_with_modules([transfer]))))
    txn = paid.transactions.first

    assert_equal "Alex Example — Dinner", txn.description
    assert_equal "Alex Example", txn.raw_description
    assert_equal " Dinner ", txn.metadata.dig("n26", "customReferenceText")
  end

  def test_space_grouped_ibans_are_compacted
    overview = N26TestData.spaces_overview
    overview["spaces"]["overview"]["items"][0]["externalIds"][0]["value"] = "ES00 1500 0000 0000 0000 1234"
    paid = normalize(raw(N26TestData.captured_context(overview: overview)))

    assert_equal "ES0015000000000000001234", paid.accounts.find { |a| a.type == "checking" }.iban
  end

  def test_struck_through_amount_is_reverted
    refunded = payload.transactions.find { |t| t.description == "Refunded Order" }
    assert_equal "reverted", refunded.status
    assert_equal "STRIKETHROUGH", refunded.metadata.dig("n26", "amountStyle")
  end

  def test_ids_are_deterministic
    again = normalize(raw)
    assert_equal payload.transactions.map(&:id).sort, again.transactions.map(&:id).sort
  end
end

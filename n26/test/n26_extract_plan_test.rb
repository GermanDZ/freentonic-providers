# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "date"
require "freentonic"
require_relative "n26_test_data"
require_relative "n26_harness"

# Runs the workflow's Extract stage — `captured:` declaration + extract plan —
# exactly as a sync does.
class N26ExtractPlanTest < Minitest::Test
  HOUR_MS = 3_600_000

  def extract(context, from_date: Date.new(2000, 1, 1))
    @stderr = StringIO.new
    N26Harness.extract(context, from_date: from_date, stderr: @stderr)
  end

  def titles(raw) = raw["space_transactions"].fetch(N26TestData::PRIMARY_ID).map { |t| t["title"] }

  def tx_at(title, ms) = N26TestData.tx(id: "id-#{title}", title: title, amount: -1.0, timestamp: ms)

  # Built around the window start in the zone the tests run in, so the
  # result is the same in any TZ: the plan keeps one extra day before the
  # window start (for a feed booked in another zone) and drops what's older.
  def test_lookback_keeps_a_day_before_the_window_start_and_drops_older
    from_date = Date.new(2024, 1, 10)
    start = Freentonic::ExtractPlan.window_start_ms(from_date)
    first_page = N26TestData.timeline_with_modules([
      tx_at("Inside", start + HOUR_MS),
      tx_at("Previous evening", start - 12 * HOUR_MS),
      tx_at("Two days back", start - 25 * HOUR_MS)
    ])
    raw = extract(N26TestData.captured_context(timeline: first_page), from_date: from_date)

    assert_equal ["Inside", "Previous evening"], titles(raw)
  end

  def test_declares_the_captured_responses_and_nothing_else
    schema = Freentonic::WorkflowSchema.load(N26Harness::WORKFLOW)
    assert_equal %w[spaces_overview space_timeline space_detail space_timeline_pages].sort, schema.captured_names.sort
    assert_nil schema.raw["credentials"], "a capture-only workflow has no credentials block"
  end

  def test_load_more_pages_extend_the_history_in_order_without_duplicates
    raw = extract(N26TestData.captured_context(pages: N26TestData.timeline_pages))
    txns = raw["space_transactions"].fetch(N26TestData::PRIMARY_ID)

    # 3 on the first page + 4 on the older pages, one of them repeated.
    assert_equal 6, txns.size
    assert_equal txns.map { |t| t["externalId"] }.uniq, txns.map { |t| t["externalId"] }
    assert_equal ["Coffee Shop", "Salary", "Refunded Order", "Bookshop", "Rent", "Refund"], titles(raw)
    assert_equal %w[TRANSACTION], txns.map { |t| t["type"] }.uniq, "page headers are dropped"
  end

  def test_reads_every_module_of_the_first_page
    first_page = N26TestData.timeline_with_modules(
      [tx_at("Module one", 1_710_504_000_000)],
      [tx_at("Module two", 1_710_417_600_000)]
    )
    raw = extract(N26TestData.captured_context(timeline: first_page))

    assert_equal ["Module one", "Module two"], titles(raw)
  end

  def test_shapes_spaces_and_transactions_keyed_by_the_opened_space
    raw = extract(N26TestData.captured_context)

    assert_equal 2, raw["spaces"].size
    assert_equal [N26TestData::PRIMARY_ID], raw["space_transactions"].keys
    assert_equal ["Coffee Shop", "Salary", "Refunded Order"], titles(raw)
  end

  # The "Load more" pages follow the opened Space; attributing another
  # Space's history to the primary account would be worse than failing.
  def test_aborts_when_the_opened_space_is_not_the_primary
    err = assert_raises(Freentonic::UserError) do
      extract(N26TestData.captured_context(detail: N26TestData.space_detail(N26TestData::SAVINGS_ID)))
    end
    assert_match(/isn't the primary/, err.message)
  end

  def test_aborts_when_the_opened_space_is_unknown
    err = assert_raises(Freentonic::UserError) do
      extract(N26TestData.captured_context(detail: { "spaceFeatures" => [] }))
    end
    assert_match(/names no Space/, err.message)
  end

  def test_required_captures_fail_the_run_when_missing
    %w[overview timeline detail].each do |missing|
      err = assert_raises(Freentonic::UserError, missing) do
        extract(N26TestData.captured_context(missing.to_sym => nil))
      end
      assert_match(/captured \w+ is missing/, err.message)
    end
  end

  def test_aborts_on_an_empty_spaces_list
    overview = { "spaces" => { "overview" => { "items" => [] } } }
    err = assert_raises(Freentonic::UserError) { extract(N26TestData.captured_context(overview: overview)) }
    assert_match(/no Spaces/, err.message)
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "date"
require "freentonic"

# Exercises fintonic/workflow.yml's `extract: plan:` orchestration — the
# zero-Ruby replacement for the old extractor.rb. Offset pagination and the
# resultList unwrap are the framework's concern (declared on the endpoints,
# covered by freentonic's api_client tests); from the plan's POV each fetch
# returns the already-flattened Array of rows. What this locks is the
# provider-specific shaping the plan now owns: the coalesced date range, the
# read+unread concat, and the dedup-by-id that collapses the overlap.
class FintonicExtractPlanTest < Minitest::Test
  WORKFLOW = File.expand_path("../workflow.yml", __dir__)

  # Stand-in for the framework-generated api_client. Records the date-window
  # kwargs each transaction fetch receives so we can assert the coalesce.
  class FakeClient
    attr_reader :calls

    def initialize(date_range:, categories:, read:, unread:)
      @date_range = date_range
      @categories = categories
      @read       = read
      @unread     = unread
      @calls      = []
    end

    def fetch_date_range = @date_range
    def fetch_categories = @categories

    def fetch_transactions(**kwargs)
      @calls << [:read, kwargs]
      @read
    end

    def fetch_unread_transactions(**kwargs)
      @calls << [:unread, kwargs]
      @unread
    end
  end

  def plan
    schema = Freentonic::WorkflowSchema.load(WORKFLOW)
    schema.raw.fetch("extract").fetch("plan")
  end

  def run_plan(client, from_date: Date.new(2026, 1, 1))
    schema    = Freentonic::WorkflowSchema.load(WORKFLOW)
    extractor = Freentonic::ExtractPlan::PlanExtractor.new(
      plan, endpoint_names: schema.api_client_endpoint_names
    )
    extractor.call(client: client, credentials: {}, from_date: from_date,
                   stdout: StringIO.new, stderr: StringIO.new)
  end

  def tx(id, extra = {}) = { "id" => id, "bankId" => "b1" }.merge(extra)

  def test_merges_read_and_unread_deduping_by_id
    client = FakeClient.new(
      date_range: { "olderTransactionUserDate" => "2020-01-01",
                    "newerTransactionUserDate" => "2026-06-30" },
      categories: { "categoryTree" => { "1" => { "name" => "Food" } } },
      read:   [tx("a"), tx("b")],
      # 'b' overlaps the read set → dropped; 'c' is new → kept.
      unread: [tx("b", "read" => false), tx("c")]
    )
    result = run_plan(client)

    assert_equal({ "1" => { "name" => "Food" } }, result["categoryTree"])
    assert_equal %w[a b c], result["transactions"].map { |t| t["id"] }
    # read row 'b' won (first occurrence), not the unread copy.
    assert_nil result["transactions"].find { |t| t["id"] == "b" }["read"]
  end

  def test_begin_date_coalesces_from_date_over_older_transaction
    client = FakeClient.new(
      date_range: { "olderTransactionUserDate" => "2015-05-05",
                    "newerTransactionUserDate" => "2026-06-30" },
      categories: {}, read: [], unread: []
    )
    run_plan(client, from_date: Date.new(2026, 3, 1))
    read_call = client.calls.find { |(kind, _)| kind == :read }[1]
    # from_date wins the coalesce; end_date comes from the date range.
    assert_equal Date.new(2026, 3, 1), read_call[:begin_date]
    assert_equal "2026-06-30", read_call[:end_date]
  end

  def test_end_date_falls_back_to_today_when_range_missing
    client = FakeClient.new(date_range: {}, categories: {}, read: [], unread: [])
    run_plan(client)
    read_call = client.calls.find { |(kind, _)| kind == :read }[1]
    assert_equal Date.today, read_call[:end_date]
  end

  def test_category_tree_defaults_to_empty_hash
    client = FakeClient.new(date_range: {}, categories: nil, read: [], unread: [])
    assert_equal({}, run_plan(client)["categoryTree"])
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "date"
require "freentonic"

# Exercises ing/workflow.yml's `extract: plan:` orchestration — the
# zero-Ruby replacement for the old extractor.rb (deleted once Ask 6's
# lookup: verb landed in freentonic).
#
# What the plan owns declaratively, and what this file pins:
#  - /position-keeping is the fatal product-list source (network failure
#    OR a 200 with no legacyProducts array both abort — an empty payload
#    would overwrite real history downstream).
#  - the V1ID→v2-UUID join (index_by builds the map, lookup: reads it
#    back per product),
#  - ONE /search call per product UUID (single-UUID body; a multi-UUID
#    body flips ING to a sign-stripping summary format),
#  - type routing: debit (1) / investment (42) / loan (77) are skipped
#    for fetch but still flow through as products (account-only),
#  - rows attach VERBATIM into the movements_by_uuid map; all shape
#    translation is the normalizer's job (pinned in ing_normalizer_test).
#
# SCA elevation is NOT here — the PSD2 handshake is workflow.yml's
# declarative elevate: block, pinned by ing_elevate_phase_test.rb.
class IngExtractPlanTest < Minitest::Test
  WORKFLOW       = File.expand_path("../workflow.yml", __dir__)
  SHORT_LOOKBACK = Date.today - 30
  LONG_LOOKBACK  = Date.today - 540

  # --- Stub api_client -----------------------------------------------
  #
  # Declared endpoints exposed as plain methods. fetch_v2_search maps
  # raw_uuid → rows and returns the concatenated rows for the requested
  # uuids (single-element in the plan's per-product calls), recording
  # each call so tests can pin the one-call-per-UUID invariant.
  class StubClient
    attr_accessor :position_keeping_response, :v2_search_rows_by_uuid
    attr_reader :v2_search_calls, :endpoint_calls

    def initialize
      @v2_search_rows_by_uuid    = {}
      @position_keeping_response = nil
      @v2_search_calls           = []
      @endpoint_calls            = []
    end

    def fetch_position_keeping
      @endpoint_calls << :fetch_position_keeping
      @position_keeping_response
    end

    def fetch_v2_search(uuids:, from_date:, to_date:)
      @endpoint_calls << :fetch_v2_search
      @v2_search_calls << { uuids: uuids, from_date: from_date, to_date: to_date }
      uuids.flat_map { |u| Array(@v2_search_rows_by_uuid[u]) }
    end
  end

  # --- Fixtures -------------------------------------------------------

  def asset_product(uuid: "p-asset", overrides: {})
    {
      "uuid"     => uuid,
      "type"     => 17, # Cuenta SIN NÓMINA
      "alias"    => "Cuenta SIN NÓMINA Hogar",
      "iban"     => "ES5914650100981714391272",
      "currency" => "EUR",
      "balance"  => 1000.0
    }.merge(overrides)
  end

  def card_product(uuid: "p-card", overrides: {})
    {
      "uuid"             => uuid,
      "type"             => 3,
      "alias"            => "Visa Crédito",
      "productNumber"    => "4174804472951018",
      "currency"         => "EUR",
      "creditLimit"      => 6500.0,
      "availableBalance" => 4317.19
    }.merge(overrides)
  end

  def investment_product(uuid: "p-valores", overrides: {})
    {
      "uuid"     => uuid,
      "type"     => 42, # Cuenta de valores
      "alias"    => "Cuenta de valores",
      "currency" => "EUR",
      "balance"  => 0.0
    }.merge(overrides)
  end

  # /search-shape rows: `amount` is a STRING (as the real endpoint
  # returns); the plan attaches them verbatim, translation is the
  # normalizer's job. kind: distinguishes asset (has `concept`) from card.
  def v2_search_rows(count:, latest_date:, raw_uuid:, start_seq: 1, kind: :asset)
    (0...count).map do |i|
      d = latest_date - i
      row = {
        "transactionId"        => { "productId" => raw_uuid,
                                    "transactionSequence" => start_seq + i },
        "amount"               => format("%.2f", -10.0 - i * 0.01),
        "balance"              => 100.0,
        "description"          => kind == :card ? "WWW.AMAZON" : "Recibo X",
        "transactionDate"      => d.iso8601,
        "transactionCode"      => kind == :card ? "TCTPV" : "RECIBSEPA",
        "subcategoryId"        => "64",
        "transactionLocalUUID" => "___V1ID___#{kind}-#{d.iso8601}-#{i}___V1ID___",
        "mode"                 => "P"
      }
      row["concept"] = "concept-#{i}" if kind == :asset
      row
    end
  end

  def position_keeping_response(asset_uuids: { "p-asset" => "raw-asset-uuid" },
                                card_uuids:  { "p-card" => "raw-card-uuid" })
    products = []
    asset_uuids.to_h.merge(card_uuids.to_h).each do |local, raw|
      products << {
        "identifiers" => [
          { "type" => "LOCAL_UUID", "value" => local },
          { "type" => "UUID",       "value" => raw }
        ]
      }
    end
    legacy = (asset_uuids.to_h.keys + card_uuids.to_h.keys).map do |u|
      u.start_with?("p-card") ? card_product(uuid: u) : asset_product(uuid: u)
    end
    { "products" => products, "legacyProducts" => legacy }
  end

  # --- Plan harness ---------------------------------------------------

  def plan
    Freentonic::WorkflowSchema.load(WORKFLOW).raw.fetch("extract").fetch("plan")
  end

  def run_plan(client, from_date:, stdout: StringIO.new, stderr: StringIO.new)
    schema    = Freentonic::WorkflowSchema.load(WORKFLOW)
    extractor = Freentonic::ExtractPlan::PlanExtractor.new(
      plan, endpoint_names: schema.api_client_endpoint_names
    )
    result = extractor.call(client: client, credentials: {}, from_date: from_date,
                            stdout: stdout, stderr: stderr)
    [result, stdout, stderr]
  end

  # Convenience: the movements a given product's local uuid resolves to.
  def movements_for(result, local_uuid)
    Array(result.fetch("movements_by_uuid")[local_uuid])
  end

  def product_in(result, local_uuid)
    result.fetch("products").find { |p| p["uuid"] == local_uuid }
  end

  # --- Happy path: /search per product -------------------------------

  def test_search_path_fetches_one_call_per_product
    client = StubClient.new
    client.position_keeping_response = position_keeping_response
    client.v2_search_rows_by_uuid["raw-asset-uuid"] =
      v2_search_rows(count: 30, latest_date: Date.today, raw_uuid: "raw-asset-uuid", kind: :asset)
    client.v2_search_rows_by_uuid["raw-card-uuid"] =
      v2_search_rows(count: 10, latest_date: Date.today, raw_uuid: "raw-card-uuid", kind: :card)

    result, = run_plan(client, from_date: SHORT_LOOKBACK)

    assert_includes client.endpoint_calls, :fetch_position_keeping
    # One /search call PER product, single-element uuids array each time.
    assert_equal 2, client.v2_search_calls.size
    assert client.v2_search_calls.all? { |c| c[:uuids].size == 1 },
           "every /search call must carry exactly one UUID"
    assert_equal %w[raw-asset-uuid raw-card-uuid],
                 client.v2_search_calls.flat_map { |c| c[:uuids] }.sort

    # Movements land in the map keyed by each product's LOCAL uuid.
    assert_equal 30, movements_for(result, "p-asset").size
    assert_equal 10, movements_for(result, "p-card").size
    # Products flow through verbatim for the normalizer to join+emit.
    assert_equal %w[p-asset p-card], result.fetch("products").map { |p| p["uuid"] }.sort
  end

  # to_date defaults to today and from_date threads through unchanged —
  # long lookback behaves identically (elevation is elevate:'s job, not
  # the plan's).
  def test_search_windows_from_from_date_to_today
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(card_uuids: {})
    client.v2_search_rows_by_uuid["raw-asset-uuid"] =
      v2_search_rows(count: 12, latest_date: Date.today, raw_uuid: "raw-asset-uuid", kind: :asset)

    result, = run_plan(client, from_date: LONG_LOOKBACK)

    call = client.v2_search_calls.first
    assert_equal LONG_LOOKBACK, call[:from_date]
    assert_equal Date.today,    call[:to_date]
    assert_equal 12, movements_for(result, "p-asset").size
  end

  # --- Per-product isolation -----------------------------------------

  def test_per_uuid_search_keeps_rows_isolated_per_product
    client = StubClient.new
    client.position_keeping_response = position_keeping_response
    # Same sequence numbers across both products — only productId differs.
    client.v2_search_rows_by_uuid["raw-asset-uuid"] =
      v2_search_rows(count: 5, latest_date: Date.today, raw_uuid: "raw-asset-uuid", kind: :asset)
    client.v2_search_rows_by_uuid["raw-card-uuid"] =
      v2_search_rows(count: 3, latest_date: Date.today, raw_uuid: "raw-card-uuid", kind: :card)

    result, = run_plan(client, from_date: SHORT_LOOKBACK)

    movements_for(result, "p-asset").each do |mv|
      assert_equal "raw-asset-uuid", mv.dig("transactionId", "productId"),
                   "asset movement leaked to wrong product"
    end
    movements_for(result, "p-card").each do |mv|
      assert_equal "raw-card-uuid", mv.dig("transactionId", "productId"),
                   "card movement leaked to wrong product"
    end
    assert_equal 5, movements_for(result, "p-asset").size
    assert_equal 3, movements_for(result, "p-card").size
  end

  # --- Rows attach verbatim ------------------------------------------

  def test_search_rows_attach_verbatim
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(asset_uuids: {})
    raw_row = {
      "transactionId" => { "productId" => "raw-card-uuid", "transactionSequence" => 618_803_278 },
      "transactionDate" => "2026-05-19",
      "description" => "WWW.AMAZON* NA43U4RA4          LUXEMBOURG     ",
      "subcategoryId" => "64",
      "amount" => "-26.59",
      "transactionCode" => "TCTPV",
      "balance" => 3862.36,
      "transactionLocalUUID" => "___V1ID___nonceX___V1ID___",
      "mode" => "P"
    }
    client.v2_search_rows_by_uuid["raw-card-uuid"] = [raw_row]

    result, = run_plan(client, from_date: SHORT_LOOKBACK)

    assert_equal raw_row, movements_for(result, "p-card").first,
                 "row must attach untranslated"
  end

  # --- Investment (type 42): excluded from fetch, kept as product ----

  def test_investment_product_excluded_from_search_but_kept
    client = StubClient.new
    client.position_keeping_response = {
      "products" => [
        { "identifiers" => [
          { "type" => "LOCAL_UUID", "value" => "p-asset" },
          { "type" => "UUID",       "value" => "raw-asset-uuid" }
        ] },
        { "identifiers" => [
          { "type" => "LOCAL_UUID", "value" => "p-valores" },
          { "type" => "UUID",       "value" => "raw-valores-uuid" }
        ] }
      ],
      "legacyProducts" => [asset_product(uuid: "p-asset"),
                           investment_product(uuid: "p-valores")]
    }
    client.v2_search_rows_by_uuid["raw-asset-uuid"] =
      v2_search_rows(count: 3, latest_date: Date.today, raw_uuid: "raw-asset-uuid", kind: :asset)

    result, stdout, = run_plan(client, from_date: SHORT_LOOKBACK)

    # Exactly one /search fires — the asset's. Investment is never queried.
    assert_equal 1, client.v2_search_calls.size
    assert_equal ["raw-asset-uuid"], client.v2_search_calls.first[:uuids]
    refute_includes client.v2_search_calls.flat_map { |c| c[:uuids] }, "raw-valores-uuid"

    # Investment stays in the product list (so the normalizer emits its
    # account) but has no movements entry.
    refute_nil product_in(result, "p-valores"), "investment product must remain in the payload"
    assert_empty movements_for(result, "p-valores")
    assert_match(/kind=investment/, stdout.string)

    assert_equal 3, movements_for(result, "p-asset").size
  end

  # --- No v2 UUID: skipped loudly, kept as product -------------------

  def test_product_without_v2_uuid_skips_with_warning
    client = StubClient.new
    client.position_keeping_response = {
      "products" => [
        { "identifiers" => [{ "type" => "LOCAL_UUID", "value" => "p-card" }] }
      ],
      "legacyProducts" => [card_product(uuid: "p-card")]
    }

    result, _stdout, stderr = run_plan(client, from_date: SHORT_LOOKBACK)

    refute_includes client.endpoint_calls, :fetch_v2_search
    assert_match(/No v2 UUID for/, stderr.string)
    refute_nil product_in(result, "p-card"), "product must stay in the payload"
    assert_empty movements_for(result, "p-card")
  end

  # --- /position-keeping failure is fatal ----------------------------

  def test_position_keeping_network_failure_aborts
    client = StubClient.new
    def client.fetch_position_keeping
      raise StandardError, "boom"
    end

    err = assert_raises(Freentonic::UserError) do
      run_plan(client, from_date: LONG_LOOKBACK)
    end
    assert_match(%r{/position-keeping failed}, err.message)
  end

  # A 200 with no legacyProducts array must abort too — otherwise an
  # empty product list emits a 0-account payload that overwrites history.
  def test_position_keeping_malformed_response_aborts
    client = StubClient.new
    client.position_keeping_response = { "wrong_shape" => true }

    err = assert_raises(Freentonic::UserError) do
      run_plan(client, from_date: LONG_LOOKBACK)
    end
    assert_match(/no legacyProducts array/, err.message)
    refute_includes client.endpoint_calls, :fetch_v2_search
  end

  # An empty-but-present legacyProducts array is legitimate (a user with
  # no products) — proceed with an empty payload, do not abort.
  def test_empty_but_present_product_list_is_not_fatal
    client = StubClient.new
    client.position_keeping_response = { "products" => [], "legacyProducts" => [] }

    result, = run_plan(client, from_date: SHORT_LOOKBACK)

    assert_empty result.fetch("products")
    assert_empty result.fetch("movements_by_uuid")
    refute_includes client.endpoint_calls, :fetch_v2_search
  end

  # --- Idempotence ----------------------------------------------------

  def test_search_path_is_idempotent_across_two_extractions
    a, = run_plan(stub_for_search_fixture, from_date: SHORT_LOOKBACK)
    b, = run_plan(stub_for_search_fixture, from_date: SHORT_LOOKBACK)

    assert_equal movement_keys(a), movement_keys(b)
    refute_empty movement_keys(a)
  end

  def stub_for_search_fixture
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(card_uuids: {})
    client.v2_search_rows_by_uuid["raw-asset-uuid"] =
      v2_search_rows(count: 25, latest_date: Date.today, raw_uuid: "raw-asset-uuid", kind: :asset)
    client
  end

  # Stable identity across extractions is the (productId, sequence) pair.
  def movement_keys(result)
    result.fetch("movements_by_uuid").values.flatten.map do |mv|
      [mv.dig("transactionId", "productId"), mv.dig("transactionId", "transactionSequence")]
    end
  end
end

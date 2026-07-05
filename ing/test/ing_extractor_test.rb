# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "date"
require "freentonic"
require_relative "../extractor"

# SCA elevation left this extractor in the elevate: migration — the
# PSD2 handshake (challenge → operator approval → commit → Bearer
# refresh → rebind) is pinned by ing_elevate_phase_test.rb against
# workflow.yml's declarative elevate: block. What this file locks is
# the remaining orchestration: preflights, /position-keeping fatality,
# UUID routing, and the one-call-per-UUID /search fetch.
class IngExtractorTest < Minitest::Test
  SHORT_LOOKBACK = Date.today - 30
  LONG_LOOKBACK  = Date.today - 540

  CAPTURED_HEADERS = {
    "Authorization"                => "Bearer captured-low-loa",
    "X-ING-ExtendedSessionContext" => "ESC-marker"
  }.freeze

  def extractor
    Freentonic::Providers::Ing::Extractor.new
  end

  # --- Stubs ----------------------------------------------------------

  # Stand-in for the YAML-built api_client. Declared endpoints are
  # exposed as plain methods. raw_request / update_auth_headers! /
  # refresh_access_token stay as recorders so tests can pin that the
  # extractor NEVER touches them — session mutation now belongs
  # exclusively to the workflow's elevate: phase.
  #
  # The CRUX of the unified-/search migration is that all product
  # kinds funnel through a SINGLE endpoint. This stub mirrors that:
  # v2_search_rows_by_uuid maps raw_uuid → rows, and fetch_v2_search
  # returns the concatenated rows for every uuid in the request
  # (preserving input order — same as the real API's cross-product
  # response).
  class StubClient
    attr_accessor :position_keeping_response, :v2_search_rows_by_uuid
    attr_reader :raw_calls, :auth_overrides, :v2_search_calls,
                :endpoint_calls

    def initialize
      @v2_search_rows_by_uuid    = {}    # raw_uuid → Array of /search row hashes
      @position_keeping_response = nil
      @raw_calls                 = []
      @v2_search_calls           = []
      @endpoint_calls            = []
      @auth_overrides            = []   # array of {headers:, host:}
    end

    # Declared endpoints ------------------------------------------------

    def fetch_position_keeping
      @endpoint_calls << :fetch_position_keeping
      @position_keeping_response
    end

    def fetch_v2_search(uuids:, from_date:, to_date:)
      @endpoint_calls << :fetch_v2_search
      @v2_search_calls << { uuids: uuids, from_date: from_date, to_date: to_date }
      uuids.flat_map { |u| Array(@v2_search_rows_by_uuid[u]) }
    end

    def refresh_access_token
      @endpoint_calls << :refresh_access_token
      nil
    end

    # Session-mutation recorders — must stay untouched -----------------

    def update_auth_headers!(headers_hash = nil, host: nil, **other_headers)
      @auth_overrides << { headers: headers_hash || other_headers, host: host }
      self
    end

    def raw_request(method:, path:, headers: {}, body: nil, base: nil, params: nil)
      @raw_calls << { method: method, path: path, headers: headers, body: body,
                      base: base, params: params }
      nil
    end
  end

  # --- Fixtures -------------------------------------------------------

  def asset_product(uuid: "p-asset", overrides: {})
    {
      "uuid"          => uuid,
      "type"          => 17, # Cuenta SIN NÓMINA
      "alias"         => "Cuenta SIN NÓMINA Hogar",
      "iban"          => "ES5914650100981714391272",
      "currency"      => "EUR",
      "balance"       => 1000.0
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
      "uuid"          => uuid,
      "type"          => 42, # Cuenta de valores
      "alias"         => "Cuenta de valores",
      "currency"      => "EUR",
      "balance"       => 0.0
    }.merge(overrides)
  end

  # Generate /search-shape rows. Note: `amount` is emitted as a
  # STRING here, matching what the real ING /search endpoint returns
  # — the extractor attaches rows verbatim; shape translation lives
  # in the normalizer. kind: distinguishes asset (has `concept`)
  # from card (no `concept`).
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
    (asset_uuids.to_h.merge(card_uuids.to_h)).each do |local, raw|
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

  def call_extractor(client, from_date:, credentials: { ing_api_headers: CAPTURED_HEADERS },
                     stdout: StringIO.new, stderr: StringIO.new)
    extractor.call(client: client, credentials: credentials, from_date: from_date,
                   stdout: stdout, stderr: stderr)
  end

  # --- Happy path: /search per product, no session mutation --------

  def test_search_path_fetches_per_product
    client = StubClient.new
    client.position_keeping_response = position_keeping_response
    client.v2_search_rows_by_uuid["raw-asset-uuid"] =
      v2_search_rows(count: 30, latest_date: Date.today, raw_uuid: "raw-asset-uuid",
                     start_seq: 1, kind: :asset)
    client.v2_search_rows_by_uuid["raw-card-uuid"] =
      v2_search_rows(count: 10, latest_date: Date.today, raw_uuid: "raw-card-uuid",
                     start_seq: 1, kind: :card)

    products = call_extractor(client, from_date: SHORT_LOOKBACK)

    assert_includes client.endpoint_calls, :fetch_position_keeping
    assert_includes client.endpoint_calls, :fetch_v2_search

    # One /search call PER product (single-element uuids array each
    # time). ING's /search switches to a sign-stripping "summary"
    # format when given a multi-UUID array — per-product calls keep
    # the detailed signed format. See extractor.rb's
    # fetch_v2_search_into_products comment.
    assert_equal 2, client.v2_search_calls.size
    sent_uuid_arrays = client.v2_search_calls.map { |c| c[:uuids] }
    assert sent_uuid_arrays.all? { |a| a.size == 1 },
           "every /search call must carry exactly one UUID"
    assert_equal %w[raw-asset-uuid raw-card-uuid].sort,
                 sent_uuid_arrays.flatten.sort

    asset = products.find { |p| p["uuid"] == "p-asset" }
    card  = products.find { |p| p["uuid"] == "p-card"  }
    assert_equal 30, asset["movements"].size
    assert_equal 10, card["movements"].size
  end

  # The extractor performs NO session mutation and NO SCA — that whole
  # lifecycle moved to workflow.yml's elevate: phase, which runs before
  # extract and rebinds the Bearer on the shared client. Long lookback
  # must behave identically to short lookback from here.
  def test_extractor_never_mutates_session_even_on_long_lookback
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(card_uuids: {})
    client.v2_search_rows_by_uuid["raw-asset-uuid"] =
      v2_search_rows(count: 12, latest_date: Date.today, raw_uuid: "raw-asset-uuid",
                     start_seq: 1, kind: :asset)

    products = call_extractor(client, from_date: LONG_LOOKBACK)

    assert_empty client.raw_calls,      "extractor must never use raw_request"
    assert_empty client.auth_overrides, "extractor must never rotate auth headers"
    refute_includes client.endpoint_calls, :refresh_access_token
    assert_equal 12, products.first["movements"].size
  end

  # --- Bearer missing: run aborts, no fallback ---------------------

  # A missing Bearer means /position-keeping is unreachable, which
  # means the product list is unknown. Continuing would produce a
  # successful 0-account payload that overwrites real history — so we
  # abort hard with a UserError instead of returning an empty Array.
  def test_missing_bearer_raises_user_error
    client = StubClient.new

    err = assert_raises(Freentonic::UserError) do
      call_extractor(client, from_date: LONG_LOOKBACK, credentials: {})
    end
    assert_match(/ing_api_headers\.Authorization not captured/, err.message)
    assert_empty client.endpoint_calls
  end

  def test_missing_bearer_short_lookback_also_raises
    client = StubClient.new
    err = assert_raises(Freentonic::UserError) do
      call_extractor(client, from_date: SHORT_LOOKBACK, credentials: {})
    end
    assert_match(/ing_api_headers\.Authorization not captured/, err.message)
  end

  # --- XSRF preflight ------------------------------------------------

  def test_missing_xsrf_cookie_warns_but_continues
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(card_uuids: {})

    stderr = StringIO.new
    call_extractor(client, from_date: SHORT_LOOKBACK,
                   credentials: { ing_api_headers: CAPTURED_HEADERS,
                                  cookie: "genoma-session-id=abc" },
                   stderr: stderr)

    assert_includes stderr.string, "XSRF-TOKEN cookie NOT present"
    assert_includes client.endpoint_calls, :fetch_position_keeping
  end

  # --- Per-product isolation ---------------------------------------

  # Per-UUID /search means each call's response goes to exactly one
  # product. Pin the invariant: rows never cross-contaminate even
  # when sequence numbers collide across products.
  def test_v2_search_per_uuid_keeps_rows_isolated_per_product
    client = StubClient.new
    client.position_keeping_response = position_keeping_response
    # Same sequence numbers across both products — only productId
    # differentiates them. If a row leaked between products, the
    # v2-seq prefix would point at the wrong UUID.
    client.v2_search_rows_by_uuid["raw-asset-uuid"] =
      v2_search_rows(count: 5, latest_date: Date.today, raw_uuid: "raw-asset-uuid",
                     start_seq: 1, kind: :asset)
    client.v2_search_rows_by_uuid["raw-card-uuid"] =
      v2_search_rows(count: 3, latest_date: Date.today, raw_uuid: "raw-card-uuid",
                     start_seq: 1, kind: :card)

    products = call_extractor(client, from_date: SHORT_LOOKBACK)

    asset = products.find { |p| p["uuid"] == "p-asset" }
    card  = products.find { |p| p["uuid"] == "p-card"  }

    # Every asset movement's transactionId carries the asset productId;
    # every card movement's carries the card productId. No
    # cross-contamination.
    asset["movements"].each do |mv|
      assert_equal "raw-asset-uuid", mv.dig("transactionId", "productId"),
                   "asset movement #{mv.inspect} leaked to wrong product"
    end
    card["movements"].each do |mv|
      assert_equal "raw-card-uuid", mv.dig("transactionId", "productId"),
                   "card movement #{mv.inspect} leaked to wrong product"
    end
    assert_equal 5, asset["movements"].size
    assert_equal 3, card["movements"].size

    # Exactly two /search calls — one per product, single-UUID each.
    assert_equal 2, client.v2_search_calls.size
    assert client.v2_search_calls.all? { |c| c[:uuids].size == 1 }
  end

  # --- /position-keeping failure: fatal ------------------------------

  def test_position_keeping_malformed_response_raises_user_error
    client = StubClient.new
    client.position_keeping_response = { "wrong_shape" => true }

    err = assert_raises(Freentonic::UserError) do
      call_extractor(client, from_date: LONG_LOOKBACK)
    end
    assert_match(%r{/position-keeping returned no legacyProducts}, err.message)
  end

  def test_position_keeping_network_failure_raises_user_error
    client = StubClient.new
    def client.fetch_position_keeping
      raise StandardError, "boom"
    end

    err = assert_raises(Freentonic::UserError) do
      call_extractor(client, from_date: LONG_LOOKBACK)
    end
    assert_match(%r{/position-keeping failed}, err.message)
    assert_match(/StandardError: boom/, err.message)
  end

  # --- v2-only path: no legacy fallback ----------------------------
  #
  # The retired legacy /movements endpoint produced the credit-card
  # dup class (transactionLocalUUID is per-request encrypted; refetches
  # of the same posting drifted ids → phantom canonical rows). The
  # cure is to never re-introduce that path: all products go through
  # /v2/products/transactions/search, same Bearer auth, stable id is
  # transactionId.transactionSequence.

  def test_credit_card_goes_through_v2_search
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(asset_uuids: {})
    client.v2_search_rows_by_uuid["raw-card-uuid"] =
      v2_search_rows(count: 80, latest_date: Date.today, raw_uuid: "raw-card-uuid",
                     start_seq: 1, kind: :card)

    products = call_extractor(client, from_date: LONG_LOOKBACK)

    assert_includes client.endpoint_calls, :fetch_v2_search
    call = client.v2_search_calls.first
    assert_equal ["raw-card-uuid"], call[:uuids]
    card = products.find { |p| p["uuid"] == "p-card" }
    assert_equal 80, card["movements"].size
  end

  # Defensive: if /position-keeping ever fails to expose a UUID for
  # any product, the run must skip it loudly rather than fall back to
  # the legacy endpoint (which would silently re-introduce the dup
  # bug). The product comes back with movements: [] and a stderr
  # warning the operator can act on.
  def test_product_without_v2_uuid_skips_with_warning
    client = StubClient.new
    # Forge a position-keeping payload where the CC product has no UUID
    # identifier (only LOCAL_UUID).
    client.position_keeping_response = {
      "products" => [
        { "identifiers" => [{ "type" => "LOCAL_UUID", "value" => "p-card" }] }
      ],
      "legacyProducts" => [card_product(uuid: "p-card")]
    }

    stderr = StringIO.new
    products = call_extractor(client, from_date: SHORT_LOOKBACK, stderr: stderr)

    # No fetchable products → /search must not fire at all.
    refute_includes client.endpoint_calls, :fetch_v2_search
    assert_match(/No v2 UUID for/, stderr.string)
    card = products.find { |p| p["uuid"] == "p-card" }
    assert_equal [], card["movements"]
  end

  # --- /search rows attach verbatim ---------------------------------

  # The extractor performs NO shape translation: /search rows land in
  # product["movements"] byte-identical to what the endpoint returned
  # (String amounts, ISO dates, transactionId envelope intact). All
  # translation — String → Numeric amount, ISO → DD/MM/YYYY dates,
  # v2-seq stable-id synthesis — is pinned in ing_normalizer_test.rb.
  def test_v2_search_rows_attach_verbatim
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(asset_uuids: {})
    raw_row = {
      "transactionId" => { "productId" => "raw-card-uuid", "transactionSequence" => 618803278 },
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

    products = call_extractor(client, from_date: SHORT_LOOKBACK)

    mv = products.find { |p| p["uuid"] == "p-card" }["movements"].first
    assert_equal raw_row, mv, "row must attach untranslated"
  end

  # --- r3 regression pin: re-extracting the same /search fixture
  # produces byte-identical ids. Pagination itself is now the
  # framework's responsibility — see api_client_test.rb upstream — so
  # we don't re-test it here.

  def test_search_path_is_idempotent_across_two_extractions
    a = call_extractor(stub_for_search_fixture, from_date: SHORT_LOOKBACK)
    b = call_extractor(stub_for_search_fixture, from_date: SHORT_LOOKBACK)

    assert_equal movement_uuids(a), movement_uuids(b)
    refute_empty movement_uuids(a)
  end

  # Investment products (Cuenta de valores, ING type 42) are silently
  # rejected by /search with HTTP 401 — and crucially, when included
  # in a multi-UUID batch they poison the entire call, returning 401
  # for every other UUID in the array too. Exclude them upfront so the
  # batch covers only /search-compatible products. The investment
  # account still gets an entry in the payload (from /position-keeping)
  # but with no transactions.
  def test_investment_products_excluded_from_search_batch
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
      v2_search_rows(count: 3, latest_date: Date.today, raw_uuid: "raw-asset-uuid",
                     start_seq: 1, kind: :asset)
    # If investment IS included in /search, the stub would also need
    # rows for it (we intentionally do not provide them — the asserted
    # behavior is that the extractor never asks).

    stdout = StringIO.new
    products = call_extractor(client, from_date: SHORT_LOOKBACK, stdout: stdout)

    # Exactly one /search fires — the asset's. Investment never gets
    # its own per-product call (skipped upfront), so the request
    # log only carries raw-asset-uuid.
    assert_equal 1, client.v2_search_calls.size
    assert_equal ["raw-asset-uuid"], client.v2_search_calls.first[:uuids]
    refute_includes client.v2_search_calls.flat_map { |c| c[:uuids] },
                    "raw-valores-uuid"

    # Investment account still flows through as a product with empty
    # movements (so the normalizer can still emit its account entry
    # with the /position-keeping balance).
    valores = products.find { |p| p["uuid"] == "p-valores" }
    refute_nil valores, "investment product must remain in the payload"
    assert_equal [], valores["movements"]

    # Operator gets a stdout breadcrumb explaining why.
    assert_match(/Skipping.*kind=investment/, stdout.string)

    # Asset still gets its rows.
    asset = products.find { |p| p["uuid"] == "p-asset" }
    assert_equal 3, asset["movements"].size
  end

  def stub_for_search_fixture
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(card_uuids: {})
    client.v2_search_rows_by_uuid["raw-asset-uuid"] =
      v2_search_rows(count: 25, latest_date: Date.today, raw_uuid: "raw-asset-uuid",
                     start_seq: 1, kind: :asset)
    client
  end

  # Raw rows carry no synthesized uuid — the stable identity across
  # extractions is the (productId, transactionSequence) pair.
  def movement_uuids(products)
    products.flat_map do |p|
      Array(p["movements"]).map do |mv|
        [mv.dig("transactionId", "productId"),
         mv.dig("transactionId", "transactionSequence")]
      end
    end
  end
end

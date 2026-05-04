# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "date"
require "freentonic"
require_relative "../extractor"

class IngExtractorTest < Minitest::Test
  SHORT_LOOKBACK = Date.today - 30   # below 60-day threshold
  LONG_LOOKBACK  = Date.today - 540  # well above threshold

  def extractor
    Freentonic::Providers::Ing::Extractor.new
  end

  # --- Stubs ----------------------------------------------------------

  class StubClient
    attr_accessor :products, :movements_by_uuid, :raw_responses, :v2_pages_by_uuid
    attr_reader :movements_calls, :raw_calls, :auth_overrides

    def initialize
      @products          = []
      @movements_by_uuid = {}
      @v2_pages_by_uuid  = {}    # raw_uuid → array of pages, each a {transactions, count, mayHasMoreElements}
      @raw_responses     = {}    # path => response (or array, or proc)
      @movements_calls   = []
      @raw_calls         = []
      @auth_overrides    = {}
    end

    def fetch_products_legacy_shape
      @products
    end

    def legacy_fetch_all_movements(v1id:, from_date:)
      @movements_calls << { v1id: v1id, from_date: from_date }
      Array(@movements_by_uuid[v1id])
    end

    def update_auth_headers!(headers)
      @auth_overrides.merge!(headers)
      self
    end

    def raw_request(method:, path:, headers: {}, body: nil, base: nil, params: nil)
      @raw_calls << { method: method, path: path, headers: headers, body: body,
                      base: base, params: params }

      # v2 transactions: dispatch by raw_uuid in the path
      if m = path.match(%r{\A/v2/products/(?<uuid>[^/]+)/transactions\z})
        offset = (params && params[:offset]) || 0
        pages = @v2_pages_by_uuid[m[:uuid]] || []
        return pages.find { |p| p["offset"] == offset } ||
               { "transactions" => [], "count" => 0, "mayHasMoreElements" => false }
      end

      stub = @raw_responses[path]
      if stub.is_a?(Array)
        stub.shift
      elsif stub.is_a?(Proc)
        stub.call(method: method, path: path, headers: headers, body: body, base: base)
      else
        stub
      end
    end
  end

  class StubPromptStore
    attr_accessor :timeout
    attr_reader :calls

    def initialize
      @calls   = []
      @timeout = false
    end

    def prompt(kind:, message:, timeout_seconds:, mask: false)
      @calls << { kind: kind, message: message, timeout_seconds: timeout_seconds }
      raise Freentonic::RemotePromptStore::Timeout if @timeout
      true
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
      "type"             => 3, # liability
      "alias"            => "Visa Crédito",
      "productNumber"    => "4174804472951018",
      "currency"         => "EUR",
      "creditLimit"      => 6500.0,
      "availableBalance" => 4317.19
    }.merge(overrides)
  end

  def movements(count:, latest_date:)
    (0...count).map do |i|
      d = latest_date - i
      { "uuid" => "mv-#{d.iso8601}-#{i}", "amount" => -10.0,
        "effectiveDate" => d.strftime("%d/%m/%Y"), "description" => "TX",
        "currency" => "EUR" }
    end
  end

  def sca_doc_response(process_id: "abc123process")
    {
      "acceptanceMethods" => [
        { "securityProcessId" => process_id,
          "code"              => "security.cipherRequest.required",
          "validationType"    => "pwd" }
      ],
      "scaStatus" => "3"
    }
  end

  def access_token_response(token: "bearer-low-loa")
    {
      "person"       => { "id" => "person-1" },
      "accessTokens" => [{ "accessToken" => token,
                           "executorLevelOfAssurance" => "0" }]
    }
  end

  def position_keeping_response(asset_uuids: { "p-asset" => "raw-asset-uuid" },
                                card_uuids:  ["p-card"])
    products = []
    asset_uuids.each do |local, raw|
      products << {
        "identifiers" => [
          { "type" => "LOCAL_UUID", "value" => local },
          { "type" => "UUID",       "value" => raw }
        ]
      }
    end
    card_uuids.each do |local|
      products << {
        "identifiers" => [
          { "type" => "LOCAL_UUID", "value" => local }
          # no UUID — credit cards' v2 uuid is blank per ING spec
        ]
      }
    end
    legacy = (asset_uuids.keys + card_uuids).map do |u|
      u.start_with?("p-card") ? card_product(uuid: u) : asset_product(uuid: u)
    end
    { "products" => products, "legacyProducts" => legacy }
  end

  def v2_page(transactions, offset:, more: false)
    { "transactions" => transactions,
      "count"        => transactions.size,
      "limit"        => 100,
      "offset"       => offset,
      "total"        => 9999,
      "mayHasMoreElements" => more,
      "moreSca"      => false }
  end

  def v2_transactions(count:, latest_date:, start_seq: 1)
    (0...count).map do |i|
      d = latest_date - i
      {
        "transactionId" => { "productId" => "raw-asset-uuid",
                             "transactionSequence" => start_seq + i },
        "amount"        => -10.0,
        "balance"       => 100.0,
        "concept"       => "concept-#{i}",
        "description"   => "TX",
        "transactionDate" => d.iso8601,
        "transactionCode" => "TRANS",
        "subcategoryId" => "1",
        "issuerId"      => "X",
        "transactionLocalUUID" => "v2-mv-#{d.iso8601}-#{i}"
      }
    end
  end

  # --- Lookback gating: short lookback never asks for elevation -----

  def test_short_lookback_skips_elevated_path
    client = StubClient.new
    client.products = [asset_product, card_product]
    client.movements_by_uuid["p-asset"] = movements(count: 100, latest_date: Date.today)
    client.movements_by_uuid["p-card"]  = movements(count: 30,  latest_date: Date.today)
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: {}, from_date: SHORT_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    # No raw_request, no prompt — pure legacy path.
    assert_empty client.raw_calls
    assert_empty prompt.calls
    assert_equal 2, products.size
    products.each { |p| refute p.key?("_partial_data_suspected"), "no breadcrumb on short-lookback runs" }
  end

  # --- Long lookback without prompt store: graceful degradation ----

  def test_long_lookback_without_prompt_store_runs_legacy_with_breadcrumb
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-asset"] = movements(count: 50, latest_date: Date.today)

    stderr = StringIO.new
    products = extractor.call(
      client: client, credentials: {}, from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: stderr
      # No remote_prompt_store — headless run.
    )

    assert_includes stderr.string, "no operator prompt store available"
    assert_empty client.raw_calls
    refute_nil products.first["_partial_data_suspected"]
  end

  # --- Long lookback + prompt store: full elevated path -------------

  def test_long_lookback_runs_full_elevated_path
    client = StubClient.new
    client.raw_responses["/genoma_api/saf/tpa/accesstoken"]   = access_token_response(token: "low-loa")
    client.raw_responses["/position-keeping"]                  = position_keeping_response
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.raw_responses["/saf/tpa/accesstoken/synchronize"]   = access_token_response(token: "high-loa")
    client.v2_pages_by_uuid["raw-asset-uuid"] = [
      v2_page(v2_transactions(count: 100, latest_date: Date.today, start_seq: 1),  offset: 0,   more: true),
      v2_page(v2_transactions(count: 100, latest_date: Date.today - 100, start_seq: 101), offset: 100, more: true),
      v2_page(v2_transactions(count: 50,  latest_date: Date.today - 200, start_seq: 201), offset: 200, more: false)
    ]
    client.movements_by_uuid["p-card"] = movements(count: 30, latest_date: Date.today)
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: {}, from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    # Bearer rotated twice: initial mint + post-SCA refresh.
    assert_equal "Bearer high-loa", client.auth_overrides["Authorization"]

    # All required raw calls fired in order.
    paths = client.raw_calls.map { |c| c[:path] }
    assert_includes paths, "/genoma_api/saf/tpa/accesstoken"
    assert_includes paths, "/position-keeping"
    assert_includes paths, "/genoma_api/rest/sca/documentation"
    assert_includes paths, "/saf/tpa/accesstoken/synchronize"
    assert paths.any? { |p| p.start_with?("/v2/products/raw-asset-uuid/transactions") }

    # Asset got 250 transactions across 3 v2 pages; card got 30 via legacy.
    asset = products.find { |p| p["uuid"] == "p-asset" }
    card  = products.find { |p| p["uuid"] == "p-card"  }
    assert_equal 250, asset["movements"].size
    assert_equal 30,  card["movements"].size
    # v2-coerced movements look like legacy shape.
    sample = asset["movements"].first
    assert_match %r{\A\d{2}/\d{2}/\d{4}\z}, sample["effectiveDate"]
    assert sample["_v2_source"]
  end

  # --- Each elevated-path leg fails → fall back to legacy -----------

  def test_bearer_mint_failure_falls_back_to_legacy
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-asset"] = movements(count: 50, latest_date: Date.today)
    client.raw_responses["/genoma_api/saf/tpa/accesstoken"] = { "accessTokens" => [] }
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: {}, from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    # Only the bearer-mint call fired before fallback.
    assert_empty prompt.calls
    refute_nil products.first["_partial_data_suspected"]
  end

  def test_position_keeping_failure_falls_back_to_legacy
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-asset"] = movements(count: 50, latest_date: Date.today)
    client.raw_responses["/genoma_api/saf/tpa/accesstoken"] = access_token_response
    client.raw_responses["/position-keeping"] = { "wrong_shape" => true }
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: {}, from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    assert_empty prompt.calls
    refute_nil products.first["_partial_data_suspected"]
  end

  def test_sca_prompt_timeout_falls_back_to_legacy
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-asset"] = movements(count: 50, latest_date: Date.today)
    client.raw_responses["/genoma_api/saf/tpa/accesstoken"]   = access_token_response
    client.raw_responses["/position-keeping"]                  = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = sca_doc_response
    prompt = StubPromptStore.new
    prompt.timeout = true

    products = extractor.call(
      client: client, credentials: {}, from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    refute_nil products.first["_partial_data_suspected"]
  end

  def test_sca_documentation_missing_security_process_id_falls_back
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-asset"] = movements(count: 50, latest_date: Date.today)
    client.raw_responses["/genoma_api/saf/tpa/accesstoken"]   = access_token_response
    client.raw_responses["/position-keeping"]                  = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = { "acceptanceMethods" => [{ "securityProcessId" => "" }] }
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: {}, from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    assert_empty prompt.calls
    refute_nil products.first["_partial_data_suspected"]
  end

  def test_refresh_bearer_failure_falls_back_to_legacy
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-asset"] = movements(count: 50, latest_date: Date.today)
    client.raw_responses["/genoma_api/saf/tpa/accesstoken"]   = access_token_response
    client.raw_responses["/position-keeping"]                  = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.raw_responses["/saf/tpa/accesstoken/synchronize"]   = { "accessTokens" => [] }
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: {}, from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    refute_nil products.first["_partial_data_suspected"]
  end

  # --- Credit cards stay on legacy even in elevated path ------------

  def test_credit_card_uses_legacy_in_elevated_path
    client = StubClient.new
    client.raw_responses["/genoma_api/saf/tpa/accesstoken"]   = access_token_response
    client.raw_responses["/position-keeping"]                  = position_keeping_response(asset_uuids: {}, card_uuids: ["p-card"])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.raw_responses["/saf/tpa/accesstoken/synchronize"]   = access_token_response(token: "high-loa")
    client.movements_by_uuid["p-card"] = movements(count: 80, latest_date: Date.today)
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: {}, from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    # No /v2/products call for the card.
    refute client.raw_calls.any? { |c| c[:path].start_with?("/v2/products") }
    # Card movements came from legacy.
    card = products.find { |p| p["uuid"] == "p-card" }
    assert_equal 80, card["movements"].size
  end

  # --- v2 → legacy shape coercion -----------------------------------

  def test_v2_to_legacy_shape_coercion
    client = StubClient.new
    client.raw_responses["/genoma_api/saf/tpa/accesstoken"]   = access_token_response
    client.raw_responses["/position-keeping"]                  = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.raw_responses["/saf/tpa/accesstoken/synchronize"]   = access_token_response
    client.v2_pages_by_uuid["raw-asset-uuid"] = [
      v2_page([{
        "transactionId" => { "productId" => "x", "transactionSequence" => 42 },
        "amount" => -55.5, "balance" => 1000.0, "concept" => "AMAZON",
        "description" => "Amazon Marketplace", "transactionDate" => "2026-04-15",
        "transactionCode" => "RECIBO", "subcategoryId" => "9", "issuerId" => "AMZN",
        "transactionLocalUUID" => "abc-123"
      }], offset: 0, more: false)
    ]
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: {}, from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    mv = products.first["movements"].first
    assert_equal "abc-123",       mv["uuid"]
    assert_equal "15/04/2026",    mv["effectiveDate"]
    assert_equal -55.5,           mv["amount"]
    assert_equal "Amazon Marketplace", mv["description"]
    assert_equal "AMAZON",        mv["store"]
    assert_equal "RECIBO",        mv["tranCode"]
    assert_equal "EUR",           mv["currency"]
    assert_equal true,            mv["_v2_source"]
    assert_equal "9",             mv["_v2_subcategoryId"]
    assert_equal 42,              mv["_v2_transactionSequence"]
  end

  # --- v2 pagination terminates on count=0 OR mayHasMoreElements=false

  def test_v2_pagination_stops_when_no_more_elements
    client = StubClient.new
    client.raw_responses["/genoma_api/saf/tpa/accesstoken"]   = access_token_response
    client.raw_responses["/position-keeping"]                  = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.raw_responses["/saf/tpa/accesstoken/synchronize"]   = access_token_response
    client.v2_pages_by_uuid["raw-asset-uuid"] = [
      v2_page(v2_transactions(count: 100, latest_date: Date.today),                offset: 0,   more: true),
      v2_page(v2_transactions(count: 50,  latest_date: Date.today - 100, start_seq: 101), offset: 100, more: false)
    ]
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: {}, from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    # 100 + 50 = 150, then stop (mayHasMoreElements=false).
    assert_equal 150, products.first["movements"].size
    v2_calls = client.raw_calls.count { |c| c[:path].start_with?("/v2/products") }
    assert_equal 2, v2_calls
  end

  # --- Backwards compat: legacy 5-kwarg call signature still works ---

  def test_legacy_signature_without_prompt_store_works
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-asset"] = movements(count: 100, latest_date: Date.today)

    products = extractor.call(
      client: client, credentials: {}, from_date: SHORT_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new
    )

    refute_empty products
  end
end

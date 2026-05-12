# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "date"
require "freentonic"
require_relative "../extractor"

class IngExtractorTest < Minitest::Test
  SHORT_LOOKBACK = Date.today - 30   # below 60-day threshold
  LONG_LOOKBACK  = Date.today - 540  # well above threshold

  CAPTURED_HEADERS = {
    "Authorization"                => "Bearer captured-low-loa",
    "X-ING-ExtendedSessionContext" => "ESC-marker"
  }.freeze

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
      @v2_pages_by_uuid  = {}    # raw_uuid → array of pages keyed on offset
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
      "type"             => 3,
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

  def access_token_response(token: "elevated-bearer")
    {
      "person"       => { "id" => "person-1" },
      "accessTokens" => [{ "accessToken" => token,
                           "executorLevelOfAssurance" => "5" }]
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
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: SHORT_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    assert_empty client.raw_calls
    assert_empty prompt.calls
    assert_equal 2, products.size
    products.each { |p| refute p.key?("_partial_data_suspected") }
  end

  # --- Long lookback without captured api headers: legacy + warning -

  def test_long_lookback_without_captured_headers_falls_back_with_warning
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-asset"] = movements(count: 50, latest_date: Date.today)
    prompt = StubPromptStore.new

    stderr = StringIO.new
    products = extractor.call(
      client: client, credentials: {},  # no ing_api_headers
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: stderr,
      remote_prompt_store: prompt
    )

    assert_includes stderr.string, "ing_api_headers.Authorization wasn't captured"
    assert_empty client.raw_calls
    assert_empty prompt.calls
    refute_nil products.first["_partial_data_suspected"]
  end

  # --- Long lookback without prompt store: legacy + warning ---------

  def test_long_lookback_without_prompt_store_falls_back_with_warning
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-asset"] = movements(count: 50, latest_date: Date.today)

    stderr = StringIO.new
    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: stderr
      # No remote_prompt_store — headless run.
    )

    assert_includes stderr.string, "no operator prompt store available"
    assert_empty client.raw_calls
    refute_nil products.first["_partial_data_suspected"]
  end

  # --- Long lookback + headers + prompt store: full v2 elevated path ---

  def test_v2_elevated_path_happy_path
    client = StubClient.new
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
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    # Client's persistent auth state is NEVER mutated — each api host
    # call gets the Bearer + ESC explicitly via raw_request `headers:`.
    assert_empty client.auth_overrides

    paths = client.raw_calls.map { |c| c[:path] }
    assert_includes paths, "/position-keeping"
    assert_includes paths, "/genoma_api/rest/sca/documentation"
    assert_includes paths, "/saf/tpa/accesstoken/synchronize"
    assert paths.any? { |p| p.start_with?("/v2/products/raw-asset-uuid/transactions") }
    refute_includes paths, "/genoma_api/saf/tpa/accesstoken"

    # Pre-SCA api host calls carry the captured (low-LoA) bearer.
    pk_call = client.raw_calls.find { |c| c[:path] == "/position-keeping" }
    assert_equal "Bearer captured-low-loa",  pk_call[:headers]["Authorization"]
    assert_equal "ESC-marker",                pk_call[:headers]["X-ING-ExtendedSessionContext"]

    # SCA endpoints (genoma host) get NO Bearer — cookie auth only.
    sca_call = client.raw_calls.find { |c| c[:path] == "/genoma_api/rest/sca/documentation" && c[:method] == :get }
    refute sca_call[:headers].key?("Authorization"), "SCA endpoints must not carry Bearer"

    # Post-refresh v2 calls carry the high-LoA bearer.
    v2_call = client.raw_calls.find { |c| c[:path].start_with?("/v2/products/raw-asset-uuid") }
    assert_equal "Bearer high-loa",   v2_call[:headers]["Authorization"]
    assert_equal "ESC-marker",         v2_call[:headers]["X-ING-ExtendedSessionContext"]

    asset = products.find { |p| p["uuid"] == "p-asset" }
    card  = products.find { |p| p["uuid"] == "p-card"  }
    assert_equal 250, asset["movements"].size
    assert_equal 30,  card["movements"].size
    sample = asset["movements"].first
    assert_match %r{\A\d{2}/\d{2}/\d{4}\z}, sample["effectiveDate"]
    assert sample["_v2_source"]
  end

  # --- v2 path failure modes → fall back to legacy ------------------

  def test_position_keeping_failure_falls_back_to_legacy
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-asset"] = movements(count: 50, latest_date: Date.today)
    client.raw_responses["/position-keeping"] = { "wrong_shape" => true }
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    assert_empty prompt.calls
    refute_nil products.first["_partial_data_suspected"]
  end

  def test_v2_failure_does_not_pollute_client_state_for_legacy_fallback
    # Regression: a previous version of this code installed the captured
    # Bearer onto the client globally via update_auth_headers!. When v2
    # failed mid-flight the legacy fallback still went out with a stale
    # Bearer, and the bank's edge proxy 401'd the request even though
    # the cookie alone would have been fine. The fix passes Bearer + ESC
    # only as per-call headers on raw_request — client state stays
    # cookie-only for the legacy path's declared endpoints.
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-asset"] = movements(count: 50, latest_date: Date.today)
    client.raw_responses["/position-keeping"] = { "wrong_shape" => true }  # forces v2 fallback
    prompt = StubPromptStore.new

    extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    # update_auth_headers! never called — client's persistent auth is unchanged.
    assert_empty client.auth_overrides
    # legacy fetch happened (the fallback) — and it ran without Bearer pollution.
    refute_empty client.movements_calls
  end

  def test_sca_prompt_timeout_falls_back_to_legacy
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-asset"] = movements(count: 50, latest_date: Date.today)
    client.raw_responses["/position-keeping"]                  = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = sca_doc_response
    prompt = StubPromptStore.new
    prompt.timeout = true

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    refute_nil products.first["_partial_data_suspected"]
  end

  def test_refresh_bearer_failure_falls_back_to_legacy
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-asset"] = movements(count: 50, latest_date: Date.today)
    client.raw_responses["/position-keeping"]                  = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.raw_responses["/saf/tpa/accesstoken/synchronize"]   = { "accessTokens" => [] }
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    refute_nil products.first["_partial_data_suspected"]
  end

  def test_sca_documentation_missing_security_process_id_falls_back
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-asset"] = movements(count: 50, latest_date: Date.today)
    client.raw_responses["/position-keeping"]                  = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = { "acceptanceMethods" => [{ "securityProcessId" => "" }] }
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    assert_empty prompt.calls
    refute_nil products.first["_partial_data_suspected"]
  end

  # --- Credit cards stay on legacy even in elevated path ------------

  def test_credit_card_uses_legacy_in_elevated_path
    client = StubClient.new
    client.raw_responses["/position-keeping"]                  = position_keeping_response(asset_uuids: {}, card_uuids: ["p-card"])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.raw_responses["/saf/tpa/accesstoken/synchronize"]   = access_token_response
    client.movements_by_uuid["p-card"] = movements(count: 80, latest_date: Date.today)
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    refute client.raw_calls.any? { |c| c[:path].start_with?("/v2/products") }
    card = products.find { |p| p["uuid"] == "p-card" }
    assert_equal 80, card["movements"].size
  end

  # --- v2 → legacy shape coercion -----------------------------------

  def test_v2_to_legacy_shape_coercion
    client = StubClient.new
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
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    mv = products.first["movements"].first
    # uuid is the stable per-position cursor (productId + sequence),
    # NOT transactionLocalUUID — the latter carries a per-request nonce
    # and would split the same ledger row into two canonical txn_ids
    # across requests.
    assert_equal "v2-seq:x:42",   mv["uuid"]
    assert_equal "abc-123",       mv["_v2_transactionLocalUUID"]
    assert_equal "15/04/2026",    mv["effectiveDate"]
    assert_equal -55.5,           mv["amount"]
    assert_equal "Amazon Marketplace", mv["description"]
    assert_equal "AMAZON",        mv["store"]
    assert_equal "RECIBO",        mv["tranCode"]
    assert_equal "EUR",           mv["currency"]
    assert_equal true,            mv["_v2_source"]
    assert_equal 42,              mv["_v2_transactionSequence"]
  end

  # Regression: ING's v2 endpoint occasionally returns the same underlying
  # ledger row twice within a single fetch, each copy carrying a different
  # `transactionLocalUUID` (per-request encrypted token). Before the fix
  # this surfaced as two distinct canonical txn_<hex> IDs downstream and
  # SimpleFIN consumers ingested duplicates. The stable cursor is
  # `transactionId.{productId, transactionSequence}` — the per-position
  # ledger key — and two records sharing it must coerce to identical
  # `uuid` so Canonical.transaction_id collapses them.
  def test_v2_same_sequence_different_local_uuid_collapses_to_one
    client = StubClient.new
    client.raw_responses["/position-keeping"]                  = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.raw_responses["/saf/tpa/accesstoken/synchronize"]   = access_token_response
    # Same productId + transactionSequence in both records — only the
    # opaque transactionLocalUUID differs (simulating ING's per-request
    # nonce). They must end up with the same `uuid` after coercion.
    client.v2_pages_by_uuid["raw-asset-uuid"] = [
      v2_page([
        {
          "transactionId" => { "productId" => "raw-asset-uuid", "transactionSequence" => 7 },
          "amount" => -132.74, "balance" => 0.0, "concept" => nil,
          "description" => "Recibo AYTO DE ALCOBENDAS I V T ",
          "transactionDate" => "2026-05-11", "transactionCode" => "RECIBSEPA",
          "transactionLocalUUID" => "___V1ID___nonceA___V1ID___"
        },
        {
          "transactionId" => { "productId" => "raw-asset-uuid", "transactionSequence" => 7 },
          "amount" => -132.74, "balance" => 0.0, "concept" => nil,
          "description" => "Recibo AYTO DE ALCOBENDAS I V T ",
          "transactionDate" => "2026-05-11", "transactionCode" => "RECIBSEPA",
          "transactionLocalUUID" => "___V1ID___nonceB___V1ID___"
        }
      ], offset: 0, more: false)
    ]
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    uuids = products.first["movements"].map { |mv| mv["uuid"] }
    assert_equal ["v2-seq:raw-asset-uuid:7", "v2-seq:raw-asset-uuid:7"], uuids
    # The local-uuid divergence is still observable for debugging.
    local_uuids = products.first["movements"].map { |mv| mv["_v2_transactionLocalUUID"] }
    assert_equal ["___V1ID___nonceA___V1ID___", "___V1ID___nonceB___V1ID___"], local_uuids
  end

  # Defensive: if ING ever omits transactionId (shouldn't happen, but the
  # v2 schema is partially documented), fall back to transactionLocalUUID
  # so the row still makes it through with a usable — if non-stable — id.
  def test_v2_missing_transaction_id_falls_back_to_local_uuid
    client = StubClient.new
    client.raw_responses["/position-keeping"]                  = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.raw_responses["/saf/tpa/accesstoken/synchronize"]   = access_token_response
    client.v2_pages_by_uuid["raw-asset-uuid"] = [
      v2_page([{
        # No "transactionId" at all
        "amount" => -10.0, "balance" => 0.0,
        "description" => "TX", "transactionDate" => "2026-04-15",
        "transactionCode" => "TRANS",
        "transactionLocalUUID" => "fallback-uuid"
      }], offset: 0, more: false)
    ]
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    assert_equal "fallback-uuid", products.first["movements"].first["uuid"]
  end

  # --- v2 pagination terminates on count=0 OR mayHasMoreElements=false

  def test_v2_pagination_stops_when_no_more_elements
    client = StubClient.new
    client.raw_responses["/position-keeping"]                  = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.raw_responses["/saf/tpa/accesstoken/synchronize"]   = access_token_response
    client.v2_pages_by_uuid["raw-asset-uuid"] = [
      v2_page(v2_transactions(count: 100, latest_date: Date.today),                offset: 0,   more: true),
      v2_page(v2_transactions(count: 50,  latest_date: Date.today - 100, start_seq: 101), offset: 100, more: false)
    ]
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    assert_equal 150, products.first["movements"].size
    v2_calls = client.raw_calls.count { |c| c[:path].start_with?("/v2/products") }
    assert_equal 2, v2_calls
  end

  # --- Backwards compat -------------------------------------------------

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

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

  # Stand-in for the YAML-built api_client. Declared endpoints are
  # exposed as plain methods; SCA endpoints (still imperative) go
  # through raw_request. update_auth_headers! records (host-scoped)
  # so tests can assert the post-SCA Bearer rotation hit the api host.
  class StubClient
    attr_accessor :products, :movements_by_uuid, :raw_responses,
                  :position_keeping_response, :refresh_token_response,
                  :v2_transactions_by_uuid
    attr_reader :movements_calls, :raw_calls, :auth_overrides, :v2_calls,
                :endpoint_calls

    def initialize
      @products                   = []
      @movements_by_uuid          = {}
      @v2_transactions_by_uuid    = {}    # raw_uuid → flat Array of v2 tx hashes
      @raw_responses              = {}    # path => response (or array, or proc)
      @position_keeping_response  = nil
      @refresh_token_response     = nil
      @movements_calls            = []
      @raw_calls                  = []
      @v2_calls                   = []
      @endpoint_calls             = []
      @auth_overrides             = []   # array of {headers:, host:}
    end

    # Declared endpoints ------------------------------------------------

    def fetch_position_keeping
      @endpoint_calls << :fetch_position_keeping
      @position_keeping_response
    end

    def fetch_v2_transactions(raw_uuid:, from_date:, to_date:)
      @endpoint_calls << :fetch_v2_transactions
      @v2_calls << { raw_uuid: raw_uuid, from_date: from_date, to_date: to_date }
      Array(@v2_transactions_by_uuid[raw_uuid])
    end

    def refresh_access_token
      @endpoint_calls << :refresh_access_token
      @refresh_token_response
    end

    def legacy_fetch_all_movements(v1id:, from_date:)
      @movements_calls << { v1id: v1id, from_date: from_date }
      Array(@movements_by_uuid[v1id])
    end

    # Auth rotation ----------------------------------------------------

    def update_auth_headers!(headers_hash = nil, host: nil, **other_headers)
      headers = headers_hash || other_headers
      @auth_overrides << { headers: headers, host: host }
      self
    end

    # SCA documentation escape hatch -----------------------------------

    def raw_request(method:, path:, headers: {}, body: nil, base: nil, params: nil)
      @raw_calls << { method: method, path: path, headers: headers, body: body,
                      base: base, params: params }
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

  # --- Short lookback + Bearer: v2 path, no SCA hop ----------------

  def test_short_lookback_uses_v2_path_without_sca
    client = StubClient.new
    client.position_keeping_response = position_keeping_response
    client.v2_transactions_by_uuid["raw-asset-uuid"] =
      v2_transactions(count: 30, latest_date: Date.today, start_seq: 1)
    client.movements_by_uuid["p-card"] = movements(count: 10, latest_date: Date.today)
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: SHORT_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    assert_includes client.endpoint_calls, :fetch_position_keeping
    assert_includes client.endpoint_calls, :fetch_v2_transactions
    # SCA documentation endpoints (still imperative) MUST NOT be hit.
    refute client.raw_calls.any? { |c| c[:path].include?("/sca/documentation") },
           "SCA endpoints must not be hit on short-lookback runs"
    refute_includes client.endpoint_calls, :refresh_access_token
    assert_empty prompt.calls
    # No Bearer rotation on short-lookback — captured value flows
    # through the host-scoped auth_headers block unchanged.
    assert_empty client.auth_overrides

    asset = products.find { |p| p["uuid"] == "p-asset" }
    assert_equal 30, asset["movements"].size
  end

  # --- Bearer missing: run returns empty, no fallback ---------------

  # A missing Bearer means /position-keeping is unreachable, which
  # means the product list is unknown. Continuing would produce a
  # successful 0-account payload that overwrites real history — so we
  # abort hard with a UserError instead of returning an empty Array.
  def test_missing_bearer_raises_user_error
    client = StubClient.new
    client.products = [asset_product]
    prompt = StubPromptStore.new

    err = assert_raises(Freentonic::UserError) do
      extractor.call(
        client: client, credentials: {},  # no ing_api_headers
        from_date: LONG_LOOKBACK,
        stdout: StringIO.new, stderr: StringIO.new,
        remote_prompt_store: prompt
      )
    end
    assert_match(/ing_api_headers\.Authorization not captured/, err.message)
    assert_empty client.raw_calls
    assert_empty prompt.calls
  end

  def test_missing_bearer_short_lookback_also_raises
    client = StubClient.new
    err = assert_raises(Freentonic::UserError) do
      extractor.call(
        client: client, credentials: {},
        from_date: SHORT_LOOKBACK,
        stdout: StringIO.new, stderr: StringIO.new
      )
    end
    assert_match(/ing_api_headers\.Authorization not captured/, err.message)
  end

  # --- Long lookback without prompt store: v2 without SCA + warning -

  def test_long_lookback_without_prompt_store_runs_v2_with_truncation_warning
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(card_uuids: [])
    client.v2_transactions_by_uuid["raw-asset-uuid"] =
      v2_transactions(count: 30, latest_date: Date.today, start_seq: 1)

    stderr = StringIO.new
    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: stderr
      # No remote_prompt_store — headless run.
    )

    assert_includes stderr.string, "no operator prompt store available"
    assert_includes stderr.string, "truncated at ING's ~52-day silent boundary"
    assert_includes client.endpoint_calls, :fetch_position_keeping
    refute client.raw_calls.any? { |c| c[:path].include?("/sca/documentation") }
    assert_empty client.auth_overrides
    assert_equal 30, products.first["movements"].size
  end

  # --- Long lookback + headers + prompt store: full v2 elevated path ---

  def test_v2_elevated_path_happy_path
    client = StubClient.new
    client.position_keeping_response = position_keeping_response
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.refresh_token_response = access_token_response(token: "high-loa")
    client.v2_transactions_by_uuid["raw-asset-uuid"] =
      v2_transactions(count: 100, latest_date: Date.today,       start_seq: 1) +
      v2_transactions(count: 100, latest_date: Date.today - 100, start_seq: 101) +
      v2_transactions(count: 50,  latest_date: Date.today - 200, start_seq: 201)
    client.movements_by_uuid["p-card"] = movements(count: 30, latest_date: Date.today)
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    # Endpoints called in the right order: position-keeping → SCA →
    # refresh → v2 transactions.
    assert_includes client.endpoint_calls, :fetch_position_keeping
    assert_includes client.endpoint_calls, :refresh_access_token
    assert_includes client.endpoint_calls, :fetch_v2_transactions

    # SCA endpoints (genoma host) — still hit via raw_request, NOT
    # part of declared endpoints.
    paths = client.raw_calls.map { |c| c[:path] }
    assert_includes paths, "/genoma_api/rest/sca/documentation"

    # Post-SCA Bearer is rotated onto the client scoped to the api host
    # only — the legacy host's cookie auth stays clean.
    rotation = client.auth_overrides.find { |o| o[:host] == "api.ing.ingdirect.es" }
    refute_nil rotation, "expected a host-scoped update_auth_headers! for api.ing.ingdirect.es"
    assert_equal "Bearer high-loa", rotation[:headers]["Authorization"]

    asset = products.find { |p| p["uuid"] == "p-asset" }
    card  = products.find { |p| p["uuid"] == "p-card"  }
    assert_equal 250, asset["movements"].size
    assert_equal 30,  card["movements"].size
    sample = asset["movements"].first
    assert_match %r{\A\d{2}/\d{2}/\d{4}\z}, sample["effectiveDate"]
    assert sample["_v2_source"]
  end

  # --- v2 path failure modes ----------------------------------------
  #
  # The cure for the r3 dup bug is that asset products never switch id
  # scheme mid-life. So failures inside the v2 path degrade in place
  # rather than falling back to a different scheme: SCA / Bearer-refresh
  # failures keep going with the captured low-LoA Bearer (truncating
  # asset history at ~52d), and /position-keeping failure aborts the
  # run entirely (no product list to extract from).

  def test_position_keeping_malformed_response_raises_user_error
    client = StubClient.new
    client.position_keeping_response = { "wrong_shape" => true }
    prompt = StubPromptStore.new

    err = assert_raises(Freentonic::UserError) do
      extractor.call(
        client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
        from_date: LONG_LOOKBACK,
        stdout: StringIO.new, stderr: StringIO.new,
        remote_prompt_store: prompt
      )
    end
    assert_match(%r{/position-keeping returned no legacyProducts}, err.message)
    assert_empty prompt.calls
  end

  def test_position_keeping_network_failure_raises_user_error
    client = StubClient.new
    def client.fetch_position_keeping
      raise StandardError, "boom"
    end
    prompt = StubPromptStore.new

    err = assert_raises(Freentonic::UserError) do
      extractor.call(
        client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
        from_date: LONG_LOOKBACK,
        stdout: StringIO.new, stderr: StringIO.new,
        remote_prompt_store: prompt
      )
    end
    assert_match(%r{/position-keeping failed}, err.message)
    assert_match(/StandardError: boom/, err.message)
  end

  def test_sca_prompt_timeout_continues_with_captured_bearer
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = sca_doc_response
    client.v2_transactions_by_uuid["raw-asset-uuid"] =
      v2_transactions(count: 12, latest_date: Date.today, start_seq: 1)
    prompt = StubPromptStore.new
    prompt.timeout = true

    stderr = StringIO.new
    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: stderr,
      remote_prompt_store: prompt
    )

    # We still hit v2, just without elevation — no Bearer rotation
    # happened, the captured value stays in place via the host-scoped
    # auth_headers block.
    assert_empty client.auth_overrides
    refute_includes client.endpoint_calls, :refresh_access_token
    assert_equal 12, products.first["movements"].size
  end

  def test_refresh_bearer_failure_continues_with_captured_bearer
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.refresh_token_response = { "accessTokens" => [] }
    client.v2_transactions_by_uuid["raw-asset-uuid"] =
      v2_transactions(count: 7, latest_date: Date.today, start_seq: 1)
    prompt = StubPromptStore.new

    stderr = StringIO.new
    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: stderr,
      remote_prompt_store: prompt
    )

    assert_includes stderr.string, "Bearer refresh failed"
    # Bearer rotation NEVER happened — refresh produced no token.
    assert_empty client.auth_overrides
    assert_equal 7, products.first["movements"].size
  end

  def test_sca_documentation_missing_process_id_continues_with_captured_bearer
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = { "acceptanceMethods" => [{ "securityProcessId" => "" }] }
    client.v2_transactions_by_uuid["raw-asset-uuid"] =
      v2_transactions(count: 5, latest_date: Date.today, start_seq: 1)
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    assert_empty prompt.calls
    refute_includes client.endpoint_calls, :refresh_access_token
    assert_empty client.auth_overrides
    assert_equal 5, products.first["movements"].size
  end

  # --- Credit cards stay on legacy even in elevated path ------------

  def test_credit_card_uses_legacy_in_elevated_path
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(asset_uuids: {}, card_uuids: ["p-card"])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.refresh_token_response = access_token_response
    client.movements_by_uuid["p-card"] = movements(count: 80, latest_date: Date.today)
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    refute_includes client.endpoint_calls, :fetch_v2_transactions
    card = products.find { |p| p["uuid"] == "p-card" }
    assert_equal 80, card["movements"].size
  end

  # --- v2 → legacy shape coercion -----------------------------------

  def test_v2_to_legacy_shape_coercion
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.refresh_token_response = access_token_response
    client.v2_transactions_by_uuid["raw-asset-uuid"] = [{
      "transactionId" => { "productId" => "x", "transactionSequence" => 42 },
      "amount" => -55.5, "balance" => 1000.0, "concept" => "AMAZON",
      "description" => "Amazon Marketplace", "transactionDate" => "2026-04-15",
      "transactionCode" => "RECIBO", "subcategoryId" => "9", "issuerId" => "AMZN",
      "transactionLocalUUID" => "abc-123"
    }]
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
    client.position_keeping_response = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.refresh_token_response = access_token_response
    # Same productId + transactionSequence in both records — only the
    # opaque transactionLocalUUID differs (simulating ING's per-request
    # nonce). They must end up with the same `uuid` after coercion.
    client.v2_transactions_by_uuid["raw-asset-uuid"] = [
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

  # If ING ever omits transactionId, the row gets `uuid: nil` and the
  # normalizer drops it. We'd rather lose a row than synthesise an
  # unstable id and re-introduce the dup bug.
  def test_v2_missing_transaction_id_emits_nil_uuid
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(card_uuids: [])
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.refresh_token_response = access_token_response
    client.v2_transactions_by_uuid["raw-asset-uuid"] = [{
      # No "transactionId" at all
      "amount" => -10.0, "balance" => 0.0,
      "description" => "TX", "transactionDate" => "2026-04-15",
      "transactionCode" => "TRANS",
      "transactionLocalUUID" => "fallback-uuid"
    }]
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    assert_nil products.first["movements"].first["uuid"]
  end

  # --- r3 regression pin: re-extracting the same v2 fixture produces
  # byte-identical ids. Since assets only ever go through v2, this is
  # the only stability guarantee we need to pin for them. Pagination
  # itself is now the framework's responsibility — see
  # workflow_schema_test.rb upstream — so we don't re-test it here.

  def test_v2_path_is_idempotent_across_two_extractions
    client_a = stub_for_v2_fixture
    client_b = stub_for_v2_fixture

    a = extractor.call(client: client_a, credentials: { ing_api_headers: CAPTURED_HEADERS },
                       from_date: SHORT_LOOKBACK, stdout: StringIO.new, stderr: StringIO.new,
                       remote_prompt_store: StubPromptStore.new)
    b = extractor.call(client: client_b, credentials: { ing_api_headers: CAPTURED_HEADERS },
                       from_date: SHORT_LOOKBACK, stdout: StringIO.new, stderr: StringIO.new,
                       remote_prompt_store: StubPromptStore.new)

    assert_equal movement_uuids(a), movement_uuids(b)
    refute_empty movement_uuids(a)
  end

  def stub_for_v2_fixture
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(card_uuids: [])
    client.v2_transactions_by_uuid["raw-asset-uuid"] =
      v2_transactions(count: 25, latest_date: Date.today, start_seq: 1)
    client
  end

  def movement_uuids(products)
    products.flat_map { |p| Array(p["movements"]).map { |mv| mv["uuid"] } }
  end
end

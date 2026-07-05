# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "date"
require "freentonic"
require_relative "../extractor"

class IngExtractorTest < Minitest::Test
  SHORT_LOOKBACK = Date.today - 30   # below 90-day SCA threshold
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
  #
  # The CRUX of the unified-/search migration is that all product
  # kinds funnel through a SINGLE multi-UUID endpoint. This stub
  # mirrors that: v2_search_rows_by_uuid maps raw_uuid → rows, and
  # fetch_v2_search returns the concatenated rows for every uuid in
  # the request (preserving input order — same as the real API's
  # cross-product response).
  class StubClient
    attr_accessor :products, :raw_responses,
                  :position_keeping_response, :refresh_token_response,
                  :v2_search_rows_by_uuid
    attr_reader :raw_calls, :auth_overrides, :v2_search_calls,
                :endpoint_calls

    def initialize
      @products                   = []
      @v2_search_rows_by_uuid     = {}    # raw_uuid → Array of /search row hashes
      @raw_responses              = {}    # path => response (or array, or proc)
      @position_keeping_response  = nil
      @refresh_token_response     = nil
      @raw_calls                  = []
      @v2_search_calls            = []
      @endpoint_calls             = []
      @auth_overrides             = []   # array of {headers:, host:}
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
      @refresh_token_response
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

  # --- Short lookback + Bearer: /search path, no SCA hop -----------

  def test_short_lookback_uses_search_without_sca
    client = StubClient.new
    client.position_keeping_response = position_keeping_response
    client.v2_search_rows_by_uuid["raw-asset-uuid"] =
      v2_search_rows(count: 30, latest_date: Date.today, raw_uuid: "raw-asset-uuid",
                     start_seq: 1, kind: :asset)
    client.v2_search_rows_by_uuid["raw-card-uuid"] =
      v2_search_rows(count: 10, latest_date: Date.today, raw_uuid: "raw-card-uuid",
                     start_seq: 1, kind: :card)
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: SHORT_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    assert_includes client.endpoint_calls, :fetch_position_keeping
    assert_includes client.endpoint_calls, :fetch_v2_search
    # SCA documentation endpoints (still imperative) MUST NOT be hit.
    refute client.raw_calls.any? { |c| c[:path].include?("/sca/documentation") },
           "SCA endpoints must not be hit on short-lookback runs"
    refute_includes client.endpoint_calls, :refresh_access_token
    assert_empty prompt.calls
    # No Bearer rotation on short-lookback — captured value flows
    # through the host-scoped auth_headers block unchanged.
    assert_empty client.auth_overrides

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

  # --- Bearer missing: run aborts, no fallback ---------------------

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

  # --- Long lookback without prompt store: /search + warning -------

  def test_long_lookback_without_prompt_store_runs_search_with_truncation_warning
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(card_uuids: {})
    client.v2_search_rows_by_uuid["raw-asset-uuid"] =
      v2_search_rows(count: 30, latest_date: Date.today, raw_uuid: "raw-asset-uuid",
                     start_seq: 1, kind: :asset)

    stderr = StringIO.new
    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: stderr
      # No remote_prompt_store — headless run.
    )

    assert_includes stderr.string, "no operator prompt store available"
    assert_includes stderr.string, "truncated at ING's 90-day silent boundary"
    assert_includes client.endpoint_calls, :fetch_position_keeping
    refute client.raw_calls.any? { |c| c[:path].include?("/sca/documentation") }
    assert_empty client.auth_overrides
    assert_equal 30, products.first["movements"].size
  end

  # --- Long lookback + headers + prompt store: full elevated path --

  def test_search_elevated_path_happy_path
    client = StubClient.new
    client.position_keeping_response = position_keeping_response
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.refresh_token_response = access_token_response(token: "high-loa")
    client.v2_search_rows_by_uuid["raw-asset-uuid"] =
      v2_search_rows(count: 100, latest_date: Date.today,       raw_uuid: "raw-asset-uuid", start_seq: 1) +
      v2_search_rows(count: 100, latest_date: Date.today - 100, raw_uuid: "raw-asset-uuid", start_seq: 101) +
      v2_search_rows(count: 50,  latest_date: Date.today - 200, raw_uuid: "raw-asset-uuid", start_seq: 201)
    client.v2_search_rows_by_uuid["raw-card-uuid"] =
      v2_search_rows(count: 30, latest_date: Date.today, raw_uuid: "raw-card-uuid",
                     start_seq: 1, kind: :card)
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    # Endpoints called in the right order: position-keeping → SCA →
    # refresh → /search.
    assert_includes client.endpoint_calls, :fetch_position_keeping
    assert_includes client.endpoint_calls, :refresh_access_token
    assert_includes client.endpoint_calls, :fetch_v2_search

    # SCA endpoints (genoma host) — still hit via raw_request, NOT
    # part of declared endpoints.
    paths = client.raw_calls.map { |c| c[:path] }
    assert_includes paths, "/genoma_api/rest/sca/documentation"

    # Post-SCA Bearer is rotated onto the client scoped to the api host
    # only — the legacy host's cookie auth stays clean.
    rotation = client.auth_overrides.find { |o| o[:host] == "api.ing.ingdirect.es" }
    refute_nil rotation, "expected a host-scoped update_auth_headers! for api.ing.ingdirect.es"
    assert_equal "Bearer high-loa", rotation[:headers]["Authorization"]

    # Per-product /search: one call per UUID. Each call carries a
    # single-element uuids array — that's what triggers ING's
    # detailed (signed) response format.
    assert_equal 2, client.v2_search_calls.size
    assert client.v2_search_calls.all? { |c| c[:uuids].size == 1 }
    asset = products.find { |p| p["uuid"] == "p-asset" }
    card  = products.find { |p| p["uuid"] == "p-card"  }
    assert_equal 250, asset["movements"].size
    assert_equal 30,  card["movements"].size
    # Rows attach VERBATIM — ISO date, String amount, untranslated.
    # Shape translation is the normalizer's job.
    sample = asset["movements"].first
    assert_match %r{\A\d{4}-\d{2}-\d{2}\z}, sample["transactionDate"]
    assert_kind_of String, sample["amount"]
    assert_equal "raw-asset-uuid", sample.dig("transactionId", "productId")
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
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: SHORT_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

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

  # --- Failure modes -----------------------------------------------
  #
  # Failures inside /search degrade in place rather than falling back
  # to a different id scheme: SCA / Bearer-refresh failures keep going
  # with the captured low-LoA Bearer (truncating history at ~90d), and
  # /position-keeping failure aborts the run entirely (no product list
  # to extract from).

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
    client.position_keeping_response = position_keeping_response(card_uuids: {})
    client.raw_responses["/genoma_api/rest/sca/documentation"] = sca_doc_response
    client.v2_search_rows_by_uuid["raw-asset-uuid"] =
      v2_search_rows(count: 12, latest_date: Date.today, raw_uuid: "raw-asset-uuid",
                     start_seq: 1, kind: :asset)
    prompt = StubPromptStore.new
    prompt.timeout = true

    stderr = StringIO.new
    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: stderr,
      remote_prompt_store: prompt
    )

    # We still hit /search, just without elevation — no Bearer rotation
    # happened, the captured value stays in place via the host-scoped
    # auth_headers block.
    assert_empty client.auth_overrides
    refute_includes client.endpoint_calls, :refresh_access_token
    assert_equal 12, products.first["movements"].size
  end

  def test_refresh_bearer_failure_continues_with_captured_bearer
    client = StubClient.new
    client.position_keeping_response = position_keeping_response(card_uuids: {})
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.refresh_token_response = { "accessTokens" => [] }
    client.v2_search_rows_by_uuid["raw-asset-uuid"] =
      v2_search_rows(count: 7, latest_date: Date.today, raw_uuid: "raw-asset-uuid",
                     start_seq: 1, kind: :asset)
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
    client.position_keeping_response = position_keeping_response(card_uuids: {})
    client.raw_responses["/genoma_api/rest/sca/documentation"] = { "acceptanceMethods" => [{ "securityProcessId" => "" }] }
    client.v2_search_rows_by_uuid["raw-asset-uuid"] =
      v2_search_rows(count: 5, latest_date: Date.today, raw_uuid: "raw-asset-uuid",
                     start_seq: 1, kind: :asset)
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
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    client.refresh_token_response = access_token_response
    client.v2_search_rows_by_uuid["raw-card-uuid"] =
      v2_search_rows(count: 80, latest_date: Date.today, raw_uuid: "raw-card-uuid",
                     start_seq: 1, kind: :card)
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: LONG_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

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
    prompt = StubPromptStore.new

    stderr = StringIO.new
    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: SHORT_LOOKBACK,
      stdout: StringIO.new, stderr: stderr,
      remote_prompt_store: prompt
    )

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
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: SHORT_LOOKBACK,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    mv = products.find { |p| p["uuid"] == "p-card" }["movements"].first
    assert_equal raw_row, mv, "row must attach untranslated"
  end

  # --- r3 regression pin: re-extracting the same /search fixture
  # produces byte-identical ids. Pagination itself is now the
  # framework's responsibility — see api_client_test.rb upstream — so
  # we don't re-test it here.

  def test_search_path_is_idempotent_across_two_extractions
    client_a = stub_for_search_fixture
    client_b = stub_for_search_fixture

    a = extractor.call(client: client_a, credentials: { ing_api_headers: CAPTURED_HEADERS },
                       from_date: SHORT_LOOKBACK, stdout: StringIO.new, stderr: StringIO.new,
                       remote_prompt_store: StubPromptStore.new)
    b = extractor.call(client: client_b, credentials: { ing_api_headers: CAPTURED_HEADERS },
                       from_date: SHORT_LOOKBACK, stdout: StringIO.new, stderr: StringIO.new,
                       remote_prompt_store: StubPromptStore.new)

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
    prompt = StubPromptStore.new

    stdout = StringIO.new
    products = extractor.call(
      client: client, credentials: { ing_api_headers: CAPTURED_HEADERS },
      from_date: SHORT_LOOKBACK,
      stdout: stdout, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    # /search was called once with the asset UUID only — investment
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

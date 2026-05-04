# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "date"
require "freentonic"
require_relative "../extractor"

class IngExtractorTest < Minitest::Test
  FROM_DATE = Date.new(2024, 11, 10)

  def extractor
    Freentonic::Providers::Ing::Extractor.new
  end

  # --- Stubs ----------------------------------------------------------

  # ApiClient stub: records every call, lets the test script the response
  # for each method (raw_request keyed on path).
  class StubClient
    attr_accessor :products, :movements_by_uuid, :raw_responses
    attr_reader :movements_calls, :raw_calls

    def initialize
      @products          = []
      @movements_by_uuid = {}
      @raw_responses     = {}  # path => response (or array for sequential calls)
      @movements_calls   = []
      @raw_calls         = []
    end

    def fetch_products_legacy_shape
      @products
    end

    def legacy_fetch_all_movements(v1id:, from_date:)
      @movements_calls << { v1id: v1id, from_date: from_date }
      result = @movements_by_uuid[v1id]
      # Sequential responses: array entries are consumed in order so we
      # can simulate "first call returns truncated, second call returns
      # full history" after SCA elevation.
      if result.is_a?(Array) && result.first.is_a?(Array)
        result.shift || []
      else
        Array(result)
      end
    end

    def raw_request(method:, path:, headers: {}, body: nil, base: nil, params: nil)
      @raw_calls << { method: method, path: path, headers: headers, body: body }
      stub = @raw_responses[path]
      if stub.is_a?(Array)
        stub.shift
      elsif stub.is_a?(Proc)
        stub.call(method: method, path: path, headers: headers, body: body)
      else
        stub
      end
    end
  end

  class StubPromptStore
    attr_accessor :next_response, :timeout
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

  def asset_product(uuid: "p-1", overrides: {})
    {
      "uuid"          => uuid,
      "type"          => 17, # Cuenta SIN NÓMINA
      "alias"         => "Cuenta SIN NÓMINA Hogar",
      "iban"          => "ES5914650100981714391272",
      "currency"      => "EUR",
      "balance"       => 1000.0
    }.merge(overrides)
  end

  # Generates `count` movements ending at `latest_date`, one per day,
  # going backwards. Used to simulate ING's response shape.
  def movements(count:, latest_date:)
    (0...count).map do |i|
      d = latest_date - i
      { "uuid" => "mv-#{d.iso8601}-#{i}", "amount" => -10.0,
        "effectiveDate" => d.strftime("%d/%m/%Y"), "description" => "TX",
        "currency" => "EUR" }
    end
  end

  def sca_doc_response(process_id: "abc123process", code: "security.cipherRequest.required")
    {
      "acceptanceMethods" => [
        { "securityProcessId" => process_id,
          "code"              => code,
          "validationType"    => "pwd",
          "status"            => 1 }
      ],
      "scaStatus" => "3"
    }
  end

  # --- No-truncation cases (existing behavior preserved) -------------

  def test_full_history_does_not_attempt_sca_or_breadcrumb
    client = StubClient.new
    client.products = [asset_product(uuid: "p-1")]
    # 100 movements, earliest = 100 days back. Within 30-day gap of
    # from_date 5 months back, so no truncation.
    client.movements_by_uuid["p-1"] = movements(count: 100, latest_date: Date.today)
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: {}, from_date: Date.today - 90,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    assert_empty client.raw_calls
    assert_empty prompt.calls
    refute products.first.key?("_partial_data_suspected")
  end

  def test_few_movements_does_not_trigger_sca_or_breadcrumb
    # New / dormant account: only 5 movements, all recent. The earliest
    # may be within from_date too, but the count guard alone is enough
    # to suppress the false-positive truncation flag.
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-1"] = movements(count: 5, latest_date: Date.today)
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: {}, from_date: FROM_DATE,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    assert_empty client.raw_calls
    assert_empty prompt.calls
    refute products.first.key?("_partial_data_suspected")
  end

  # --- Headless run (no prompt store): degrades to breadcrumb --------

  def test_truncation_without_prompt_store_records_breadcrumb_only
    client = StubClient.new
    client.products = [asset_product]
    # 50 movements, earliest at today - 49 days. from_date is FROM_DATE
    # (~18 months back). Big gap → truncated.
    client.movements_by_uuid["p-1"] = movements(count: 50, latest_date: Date.today)

    products = extractor.call(
      client: client, credentials: {}, from_date: FROM_DATE,
      stdout: StringIO.new, stderr: StringIO.new
      # No remote_prompt_store kwarg
    )

    assert_empty client.raw_calls
    breadcrumb = products.first["_partial_data_suspected"]
    refute_nil breadcrumb
    assert_equal "sca_elevation_required_suspected", breadcrumb["reason"]
    assert_equal 50, breadcrumb["movement_count"]
  end

  # --- Happy path: SCA elevation succeeds, re-fetch closes the gap ---

  def test_sca_elevation_happy_path_refetches_and_clears_breadcrumb
    client = StubClient.new
    client.products = [asset_product]
    # First call returns truncated 50 movements; second call (post-SCA)
    # returns 540 movements covering the full from_date window.
    client.movements_by_uuid["p-1"] = [
      movements(count: 50,  latest_date: Date.today),
      movements(count: 540, latest_date: Date.today)
    ]
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [
      sca_doc_response,    # GET (initiate)
      {}                   # PUT (commit) — empty 200
    ]
    prompt = StubPromptStore.new

    stderr = StringIO.new
    products = extractor.call(
      client: client, credentials: {}, from_date: FROM_DATE,
      stdout: StringIO.new, stderr: stderr,
      remote_prompt_store: prompt
    )

    # Movements were fetched twice (initial + post-SCA re-fetch).
    assert_equal 2, client.movements_calls.size
    # Two raw calls: GET sca/documentation (initiate) + PUT (commit).
    assert_equal 2, client.raw_calls.size
    assert_equal :get, client.raw_calls[0][:method]
    assert_equal "1",  client.raw_calls[0][:headers]["x-ing-reset-validations"]
    assert_equal :put, client.raw_calls[1][:method]
    assert_equal "abc123process", client.raw_calls[1][:headers]["x-ing-securityprocessid"]
    assert_equal "abc123process", client.raw_calls[1][:body]["processId"]
    # Operator was prompted exactly once with a confirm.
    assert_equal 1, prompt.calls.size
    assert_equal :confirm, prompt.calls.first[:kind]
    # After re-fetch, the product no longer looks truncated, so no
    # breadcrumb on the canonical shape.
    refute products.first.key?("_partial_data_suspected")
  end

  def test_sca_elevation_ineffective_refetch_warns_explicitly
    # Real-world failure mode: SCA flow runs to completion, prompt is
    # approved, PUT commits, but the re-fetch comes back with the same
    # window as before — meaning the elevation didn't apply to the
    # legacy endpoint we're hitting. Stderr should name the hypothesis
    # so operators don't have to diff against source.
    client = StubClient.new
    client.products = [asset_product]
    same_window = movements(count: 50, latest_date: Date.today)
    client.movements_by_uuid["p-1"] = [same_window, same_window.dup]
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    prompt = StubPromptStore.new

    stderr = StringIO.new
    products = extractor.call(
      client: client, credentials: {}, from_date: FROM_DATE,
      stdout: StringIO.new, stderr: stderr,
      remote_prompt_store: prompt
    )

    assert_includes stderr.string, "SCA elevation succeeded but"
    assert_includes stderr.string, "did not return older history"
    assert_includes stderr.string, "v2/products"
    # Breadcrumb still stamped — downstream tooling sees the truncation.
    refute_nil products.first["_partial_data_suspected"]
  end

  # --- SCA failure modes: each one degrades cleanly to breadcrumb ----

  def test_sca_documentation_missing_acceptance_methods_falls_back
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-1"] = movements(count: 50, latest_date: Date.today)
    client.raw_responses["/genoma_api/rest/sca/documentation"] = { "acceptanceMethods" => [] }
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: {}, from_date: FROM_DATE,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    assert_empty prompt.calls
    refute_nil products.first["_partial_data_suspected"]
  end

  def test_sca_documentation_missing_security_process_id_falls_back
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-1"] = movements(count: 50, latest_date: Date.today)
    client.raw_responses["/genoma_api/rest/sca/documentation"] = {
      "acceptanceMethods" => [{ "securityProcessId" => "" }]
    }
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: {}, from_date: FROM_DATE,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    assert_empty prompt.calls
    refute_nil products.first["_partial_data_suspected"]
  end

  def test_prompt_timeout_falls_back_to_breadcrumb
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-1"] = movements(count: 50, latest_date: Date.today)
    client.raw_responses["/genoma_api/rest/sca/documentation"] = sca_doc_response
    prompt = StubPromptStore.new
    prompt.timeout = true

    products = extractor.call(
      client: client, credentials: {}, from_date: FROM_DATE,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    # Only the GET hit; the PUT never fired.
    assert_equal 1, client.raw_calls.size
    assert_equal 1, client.movements_calls.size
    refute_nil products.first["_partial_data_suspected"]
  end

  def test_put_commit_failure_falls_back_to_breadcrumb
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-1"] = movements(count: 50, latest_date: Date.today)
    raise_on_put = ->(method:, path:, headers:, body:) {
      raise Freentonic::ApiClient::ApiError.new(403, "denied") if method == :put
      sca_doc_response
    }
    client.raw_responses["/genoma_api/rest/sca/documentation"] = raise_on_put
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: {}, from_date: FROM_DATE,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    refute_nil products.first["_partial_data_suspected"]
  end

  # --- Multi-product: one elevation covers all truncated products ---

  def test_one_elevation_refetches_every_truncated_product
    p1 = asset_product(uuid: "p-1")
    p2 = asset_product(uuid: "p-2", overrides: { "alias" => "Other Checking" })
    p3_full = asset_product(uuid: "p-3", overrides: {
      "type" => 20, "alias" => "Cuenta NARANJA"
    })

    client = StubClient.new
    client.products = [p1, p2, p3_full]
    client.movements_by_uuid["p-1"] = [
      movements(count: 50,  latest_date: Date.today),
      movements(count: 540, latest_date: Date.today)
    ]
    client.movements_by_uuid["p-2"] = [
      movements(count: 50,  latest_date: Date.today),
      movements(count: 540, latest_date: Date.today)
    ]
    client.movements_by_uuid["p-3"] = movements(count: 540, latest_date: Date.today)
    client.raw_responses["/genoma_api/rest/sca/documentation"] = [sca_doc_response, {}]
    prompt = StubPromptStore.new

    products = extractor.call(
      client: client, credentials: {}, from_date: FROM_DATE,
      stdout: StringIO.new, stderr: StringIO.new,
      remote_prompt_store: prompt
    )

    # Operator prompted exactly once.
    assert_equal 1, prompt.calls.size
    # Only one elevation handshake total (GET + PUT).
    assert_equal 2, client.raw_calls.size
    # p-1 and p-2 fetched twice (initial + post-SCA); p-3 fetched once.
    assert_equal 5, client.movements_calls.size
    # Truncation cleared on all three.
    products.each do |product|
      refute product.key?("_partial_data_suspected"),
             "expected #{product['uuid']} to no longer look truncated"
    end
  end

  # --- Backwards compat: legacy 5-kwarg call signature still works ---

  def test_legacy_signature_without_prompt_store_works
    client = StubClient.new
    client.products = [asset_product]
    client.movements_by_uuid["p-1"] = movements(count: 100, latest_date: Date.today)

    products = extractor.call(
      client: client, credentials: {}, from_date: Date.today - 60,
      stdout: StringIO.new, stderr: StringIO.new
    )

    refute_empty products
  end
end

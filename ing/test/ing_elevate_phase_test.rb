# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "date"
require "freentonic"

# Exercises ing/workflow.yml's `elevate:` block — the declarative
# replacement for the SCA handshake extractor.rb used to run
# imperatively (attempt_sca_elevation + refresh_bearer_after_sca +
# update_auth_headers!). The interpreter mechanics (step dispatch,
# templating, prompt-store wiring) are the framework's concern, covered
# upstream; what this file locks is ING's wiring: the 90-day gate, the
# challenge → approval → commit → refresh → rebind sequence, the
# process_id data-flow out of the challenge response, and the
# host-scoping of the rebound Bearer.
class IngElevatePhaseTest < Minitest::Test
  WORKFLOW = File.expand_path("../workflow.yml", __dir__)

  def schema
    @schema ||= Freentonic::WorkflowSchema.load(WORKFLOW)
  end

  def spec
    schema.elevate_spec
  end

  # Stand-in for the YAML-built api_client: the three endpoints the
  # elevate steps fetch, plus the update_auth_headers! recorder that
  # rebind_credential lands on.
  class FakeClient
    attr_accessor :challenge_response, :commit_response, :refresh_response
    attr_reader :calls, :auth_overrides

    def initialize
      @calls          = []
      @auth_overrides = []
    end

    def sca_documentation_challenge
      @calls << [:sca_documentation_challenge]
      @challenge_response
    end

    def sca_documentation_commit(process_id:)
      @calls << [:sca_documentation_commit, process_id]
      @commit_response
    end

    def refresh_access_token
      @calls << [:refresh_access_token]
      @refresh_response
    end

    def update_auth_headers!(headers_hash = nil, host: nil, **other_headers)
      @auth_overrides << { headers: headers_hash || other_headers, host: host }
      self
    end
  end

  class FakePromptStore
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

  def challenge_response(process_id: "abc123process", code: "security.cipherRequest.required")
    {
      "acceptanceMethods" => [
        { "securityProcessId" => process_id,
          "code"              => code,
          "validationType"    => "pwd" }
      ],
      "scaStatus" => "3"
    }
  end

  def refresh_response(token: "elevated-bearer")
    {
      "person"       => { "id" => "person-1" },
      "accessTokens" => [{ "accessToken" => token,
                           "executorLevelOfAssurance" => "5" }]
    }
  end

  def elevation_scope(lookback_days:)
    Freentonic::ExtractPlan.seed_scope(Date.today - lookback_days)
  end

  def run_elevation(client, prompt_store:, lookback_days: 540)
    Freentonic::Elevate::Interpreter.new(
      steps:          Array(spec["steps"]),
      endpoint_names: schema.api_client_endpoint_names,
      stdout:         StringIO.new,
      stderr:         StringIO.new,
      prompt_store:   prompt_store
    ).run(client: client, scope: elevation_scope(lookback_days: lookback_days))
  end

  # --- Block policy ---------------------------------------------------

  # degrade is load-bearing: SCA timeout, missing processId or empty
  # refreshed token must warn and continue with the captured low-LoA
  # Bearer (history truncates at ~90d), never fail the run.
  def test_declares_degrade_on_failure
    refute_nil spec, "ing/workflow.yml must declare an elevate: block"
    assert_equal "degrade", spec["on_failure"]
  end

  # The 90-day gate: /search serves up to 90d of history on a low-LoA
  # Bearer, so a default (90d) run must skip the SCA dance entirely —
  # elevation only fires when the operator asks for older history.
  def test_when_gate_sits_exactly_at_90_days
    gate = spec["when"]
    refute_nil gate, "elevate: must be gated on lookback_days"
    refute Freentonic::ExtractPlan::WhenGate.passes?(gate, elevation_scope(lookback_days: 90)),
           "a 90d lookback must NOT trigger elevation"
    assert Freentonic::ExtractPlan::WhenGate.passes?(gate, elevation_scope(lookback_days: 91)),
           "a 91d lookback must trigger elevation"
  end

  # --- Happy path -------------------------------------------------------

  def test_happy_path_challenge_approval_commit_refresh_rebind
    client = FakeClient.new
    client.challenge_response = challenge_response(process_id: "proc-77")
    client.refresh_response   = refresh_response(token: "high-loa")
    prompt = FakePromptStore.new

    run_elevation(client, prompt_store: prompt)

    # Endpoint order: challenge → (approval) → commit → refresh.
    assert_equal [[:sca_documentation_challenge],
                  [:sca_documentation_commit, "proc-77"],
                  [:refresh_access_token]], client.calls

    # Operator was prompted exactly once, between challenge and commit,
    # with the live challenge code embedded and the workflow's timeout.
    assert_equal 1, prompt.calls.size
    assert_equal :confirm, prompt.calls.first[:kind]
    assert_equal 180, prompt.calls.first[:timeout_seconds]
    assert_includes prompt.calls.first[:message], "approve"
    assert_includes prompt.calls.first[:message], "security.cipherRequest.required"

    # The refreshed Bearer is rebound host-scoped to the api host ONLY —
    # the legacy host stays cookie-only.
    assert_equal 1, client.auth_overrides.size
    rebind = client.auth_overrides.first
    assert_equal "api.ing.ingdirect.es", rebind[:host]
    assert_equal({ "Authorization" => "Bearer high-loa" }, rebind[:headers])
  end

  # --- Failure modes (all route to the stage's on_failure: degrade) ---

  def test_prompt_timeout_propagates_before_commit
    client = FakeClient.new
    client.challenge_response = challenge_response
    prompt = FakePromptStore.new
    prompt.timeout = true

    assert_raises(Freentonic::RemotePromptStore::Timeout) do
      run_elevation(client, prompt_store: prompt)
    end
    # The commit must NOT fire on an unapproved challenge, and no
    # credential may have been rebound.
    refute client.calls.any? { |c| c.first == :sca_documentation_commit }
    assert_empty client.auth_overrides
  end

  def test_missing_operator_channel_fails_rather_than_hanging
    client = FakeClient.new
    client.challenge_response = challenge_response

    err = assert_raises(Freentonic::UserError) do
      run_elevation(client, prompt_store: nil)
    end
    assert_match(/no operator channel/, err.message)
    assert_empty client.auth_overrides
  end

  def test_empty_refreshed_token_fails_the_rebind
    client = FakeClient.new
    client.challenge_response = challenge_response
    client.refresh_response   = { "accessTokens" => [] }
    prompt = FakePromptStore.new

    err = assert_raises(Freentonic::UserError) do
      run_elevation(client, prompt_store: prompt)
    end
    assert_match(/rebind_credential\[Authorization\]/, err.message)
    # A truncated "Bearer " header must never be installed.
    assert_empty client.auth_overrides
  end
end

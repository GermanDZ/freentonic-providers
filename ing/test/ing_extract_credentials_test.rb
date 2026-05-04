# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "freentonic"

# Verifies that the ING workflow YAML, loaded through the framework's
# Source wrapper, correctly validates and maps credentials captured by
# the declarative phase.
class IngExtractCredentialsTest < Minitest::Test
  WORKFLOW_PATH = File.expand_path("../workflow.yml", __dir__)

  def source
    Freentonic::Source.new(workflow_path: WORKFLOW_PATH)
  end

  def test_uses_workflow_context_credentials_when_available
    stdout = StringIO.new
    credentials = source.extract_credentials(
      nil,
      workflow_context: {
        "cookie"              => "genoma-session-id=abc; other=xyz",
        "cookie_cookie_count" => 2
      },
      stdout: stdout,
      stderr: StringIO.new
    )

    # ing_local_storage and ing_api_headers are optional captures (gated
    # on the bank's frontend having fired /position-keeping by capture
    # time); when absent the map step still emits the keys as nil so the
    # api_client's accessor methods exist.
    assert_equal "genoma-session-id=abc; other=xyz", credentials[:cookie]
    assert_nil credentials[:ing_local_storage]
    assert_nil credentials[:ing_api_headers]
    assert_includes stdout.string, "[yml] credentials captured by declarative phase"
    assert_includes stdout.string, "✓ (2 cookies)"
  end

  def test_passes_through_optional_browser_state_captures
    stdout = StringIO.new
    credentials = source.extract_credentials(
      nil,
      workflow_context: {
        "cookie"              => "genoma-session-id=abc",
        "ing_local_storage"   => { "ExtendedSessionContext" => "eyJ..." },
        "ing_api_headers"     => { "Authorization" => "Bearer eyJ...",
                                   "X-XSRF-TOKEN"  => "csrf-1" }
      },
      stdout: stdout,
      stderr: StringIO.new
    )

    assert_equal({ "ExtendedSessionContext" => "eyJ..." }, credentials[:ing_local_storage])
    assert_equal "Bearer eyJ...", credentials[:ing_api_headers]["Authorization"]
    assert_equal "csrf-1",        credentials[:ing_api_headers]["X-XSRF-TOKEN"]
  end

  def test_raises_when_cookie_missing
    error = assert_raises(Freentonic::UserError) do
      source.extract_credentials(nil, workflow_context: {}, stdout: StringIO.new, stderr: StringIO.new)
    end
    assert_includes error.message, "cookie"
  end

  def test_raises_when_cookie_lacks_genoma_session_id
    error = assert_raises(Freentonic::UserError) do
      source.extract_credentials(
        nil,
        workflow_context: { "cookie" => "other=xyz" },
        stdout: StringIO.new,
        stderr: StringIO.new
      )
    end
    assert_includes error.message, "genoma-session-id="
  end
end

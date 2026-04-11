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

    assert_equal({ cookie: "genoma-session-id=abc; other=xyz" }, credentials)
    assert_includes stdout.string, "[yml] credentials captured by declarative phase"
    assert_includes stdout.string, "✓ (2 cookies)"
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

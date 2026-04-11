# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "freentonic"

# Verifies that the Unicaja workflow YAML validates and maps the
# declarative capture phase's cookie + tokencsrf into credentials.
class UnicajaExtractCredentialsTest < Minitest::Test
  WORKFLOW_PATH = File.expand_path("../workflow.yml", __dir__)

  def source
    Freentonic::Source.new(workflow_path: WORKFLOW_PATH)
  end

  def test_uses_workflow_context_credentials_when_available
    stdout = StringIO.new
    credentials = source.extract_credentials(
      nil,
      workflow_context: {
        "cookie"              => "sid=abc",
        "cookie_cookie_count" => 1,
        "tokencsrf"           => "csrf-123"
      },
      stdout: stdout,
      stderr: StringIO.new
    )

    assert_equal({ cookie: "sid=abc", tokencsrf: "csrf-123" }, credentials)
    assert_includes stdout.string, "[yml] credentials captured by declarative phase"
  end
end

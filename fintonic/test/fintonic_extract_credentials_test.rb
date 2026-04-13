# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "freentonic"

class FintonicExtractCredentialsTest < Minitest::Test
  WORKFLOW_PATH = File.expand_path("../workflow.yml", __dir__)

  def source
    Freentonic::Source.new(workflow_path: WORKFLOW_PATH)
  end

  def test_maps_bearer_token_to_credentials
    credentials = source.extract_credentials(
      nil,
      workflow_context: {
        "bearer_token" => "Bearer eyJhbGciOi..."
      },
      stdout: StringIO.new,
      stderr: StringIO.new
    )

    assert_equal({ bearer_token: "Bearer eyJhbGciOi..." }, credentials)
  end

  def test_raises_when_bearer_token_missing
    assert_raises(Freentonic::UserError) do
      source.extract_credentials(
        nil,
        workflow_context: {},
        stdout: StringIO.new,
        stderr: StringIO.new
      )
    end
  end

  def test_raises_when_bearer_token_empty
    assert_raises(Freentonic::UserError) do
      source.extract_credentials(
        nil,
        workflow_context: { "bearer_token" => "" },
        stdout: StringIO.new,
        stderr: StringIO.new
      )
    end
  end

  def test_raises_when_bearer_token_lacks_prefix
    assert_raises(Freentonic::UserError) do
      source.extract_credentials(
        nil,
        workflow_context: { "bearer_token" => "not-a-bearer-token" },
        stdout: StringIO.new,
        stderr: StringIO.new
      )
    end
  end
end

require "minitest/autorun"
require "stringio"
require "freentonic"

class RevolutExtractCredentialsTest < Minitest::Test
  WORKFLOW_PATH = File.expand_path("../workflow.yml", __dir__)

  def source
    Freentonic::Source.new(workflow_path: WORKFLOW_PATH)
  end

  def test_maps_captured_context_to_credentials
    credentials = source.extract_credentials(
      nil,
      workflow_context: {
        "cookie"      => "r_token=abc; r_sid=xyz",
        "x_device_id" => "device-id-placeholder"
      },
      stdout: StringIO.new,
      stderr: StringIO.new
    )

    assert_equal(
      { cookie: "r_token=abc; r_sid=xyz", x_device_id: "device-id-placeholder" },
      credentials
    )
  end

  def test_raises_when_required_key_missing
    assert_raises(Freentonic::UserError) do
      source.extract_credentials(
        nil,
        workflow_context: {},
        stdout: StringIO.new,
        stderr: StringIO.new
      )
    end
  end
end

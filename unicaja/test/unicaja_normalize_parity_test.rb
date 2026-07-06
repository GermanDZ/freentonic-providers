# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "stringio"
require "freentonic"

# Golden-parity gate for the ING normalizer migration (Ruby →
# normalize: plan:). For every raw payload in test/fixtures/*.json (the
# live extract shape: { products, movements_by_uuid } with raw /v2/search
# rows), the plan the workflow now declares must reproduce the canonical
# payload the old normalizer.rb produced — captured in test/golden/*.json
# via `rake golden:dump[unicaja]` while the Ruby normalizer was still live.
#
# The goldens are the frozen truth; they stay as the permanent regression
# net after normalizer.rb is deleted. summary.generated_at (wall-clock) is
# stripped on both sides so the comparison is deterministic.
class UnicajaNormalizeParityTest < Minitest::Test
  PROVIDER_DIR = File.expand_path("..", __dir__)
  WORKFLOW     = File.join(PROVIDER_DIR, "workflow.yml")
  FIXTURE_DIR  = File.join(__dir__, "fixtures")
  GOLDEN_DIR   = File.join(__dir__, "golden")

  def normalizer
    @normalizer ||= Freentonic::Normalizers::Builder.for_workflow(
      WORKFLOW, stdout: StringIO.new, stderr: StringIO.new
    )
  end

  def canonical_hash(payload)
    h = payload.to_h
    h["summary"]&.delete("generated_at")
    h
  end

  Dir[File.join(FIXTURE_DIR, "*.json")].sort.each do |fixture|
    name = File.basename(fixture, ".json")
    define_method("test_parity_#{name}") do
      raw    = JSON.parse(File.read(fixture))
      golden = JSON.parse(File.read(File.join(GOLDEN_DIR, "#{name}.json")))
      actual = canonical_hash(normalizer.call(raw))

      assert_equal golden, actual,
                   "plan output diverged from golden for fixture #{name}"
    end
  end

  def test_the_workflow_actually_declares_a_plan
    schema = Freentonic::WorkflowSchema.load(WORKFLOW)
    assert schema.normalizer.is_a?(Hash) && schema.normalizer.key?("plan"),
           "expected normalize: plan: in workflow.yml"
    assert_kind_of Freentonic::Normalizers::Plan, normalizer
  end

  def test_all_fixtures_have_goldens
    fixtures = Dir[File.join(FIXTURE_DIR, "*.json")].map { |f| File.basename(f) }.sort
    goldens  = Dir[File.join(GOLDEN_DIR, "*.json")].map { |f| File.basename(f) }.sort
    assert_equal fixtures, goldens, "every fixture must have a committed golden"
  end
end

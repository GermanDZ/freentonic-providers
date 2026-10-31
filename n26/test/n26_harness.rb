# frozen_string_literal: true

require "date"
require "stringio"
require "freentonic"

# Runs the N26 workflow's stages exactly as a sync does, over synthetic
# captures (see N26TestData).
module N26Harness
  WORKFLOW = File.expand_path("../workflow.yml", __dir__)

  module_function

  # The Extract stage on a connect-phase context: the workflow's `captured:`
  # declaration (and its required: checks) selects what the plan sees, then
  # the plan runs with the lookback that starts at `from_date`.
  def extract(workflow_context, from_date: Date.new(2000, 1, 1), stderr: StringIO.new)
    context = {
      source: Freentonic::Source.new(workflow_path: WORKFLOW), credentials: {},
      workflow_context: workflow_context, lookback_days: (Date.today - from_date).to_i,
      stdout: StringIO.new, stderr: stderr
    }
    Freentonic::Stages::Extract.new(context: context).call[:raw]
  end

  def normalize(raw)
    Freentonic::Normalizers::Builder.for_workflow(WORKFLOW, stdout: StringIO.new, stderr: StringIO.new).call(raw)
  end
end

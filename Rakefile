require "rake/testtask"

# One test task per provider directory (ing/test/**, unicaja/test/**, ...).
# Running `rake test` runs them all; `rake test:ing` runs just ING's.
# Shared-helper tests (canonical_builder, helpers, …) live in the
# freentonic gem itself as of 0.3.0 — run them via `bundle exec rake
# test` from that repo.
provider_dirs = Dir["*/test"].map { |d| File.dirname(d) }.sort

namespace :test do
  provider_dirs.each do |provider|
    Rake::TestTask.new(provider.to_sym) do |t|
      t.libs << "#{provider}"
      t.test_files = FileList["#{provider}/test/**/*_test.rb"]
      t.warning = false
      t.description = "Run tests for the #{provider} provider"
    end
  end
end

desc "Run tests for every provider"
task test: provider_dirs.map { |p| "test:#{p}" }

task default: :test

# --- Golden canonical payloads --------------------------------------------
#
# Golden-parity harness for the normalizer migration (Ruby → normalize:
# plan:). For each raw payload in <provider>/test/fixtures/*.json, dumps
# the canonical payload the provider's workflow-configured normalizer
# produces to <provider>/test/golden/<name>.json.
#
# Protocol: run `rake golden:dump[revolut]` with the CURRENT (Ruby)
# normalizer, commit the goldens, then write the plan. The provider's
# parity test asserts the plan reproduces every golden byte-for-byte;
# the goldens stay as the permanent regression net after normalizer.rb
# is deleted. Re-dumping post-migration (against the plan) is only for a
# deliberate canonical-model change — never to paper over a diff.
namespace :golden do
  desc "Dump golden canonical payloads for a provider: rake golden:dump[revolut]"
  task :dump, [:provider] do |_, args|
    require "json"
    require "stringio"
    require "fileutils"
    require "freentonic"

    provider = args[:provider] or abort "Usage: rake golden:dump[provider_name]"
    workflow = File.join(provider, "workflow.yml")
    abort "No workflow at #{workflow}" unless File.exist?(workflow)

    fixtures = Dir[File.join(provider, "test", "fixtures", "*.json")].sort
    abort "No fixtures in #{provider}/test/fixtures/" if fixtures.empty?

    golden_dir = File.join(provider, "test", "golden")
    FileUtils.mkdir_p(golden_dir)

    normalizer = Freentonic::Normalizers::Builder.for_workflow(
      workflow, stdout: StringIO.new, stderr: StringIO.new
    )

    fixtures.each do |fixture|
      name = File.basename(fixture, ".json")
      raw  = JSON.parse(File.read(fixture))
      hash = normalizer.call(raw).to_h
      # summary.generated_at is wall-clock — strip it so goldens are
      # deterministic and the plan-parity test can compare byte-for-byte.
      # The parity test strips the same field from the plan's output.
      hash["summary"]&.delete("generated_at")
      out = File.join(golden_dir, "#{name}.json")
      File.write(out, "#{JSON.pretty_generate(hash)}\n")
      puts "  #{fixture} → #{out}"
    end
    puts "Dumped #{fixtures.size} golden(s) for #{provider}."
  end
end

# --- Scaffold a new provider ---

desc "Scaffold a new provider: rake new[provider_name]"
task :new, [:name] do |_, args|
  name = args[:name]
  abort "Usage: rake new[provider_name]" unless name && !name.empty?

  require "freentonic/providers/scaffold"
  scaffold = Freentonic::Providers::Scaffold.new(name)

  if Dir.exist?(scaffold.dir)
    abort "Error: #{scaffold.dir} already exists"
  end

  scaffold.generate!

  puts "Created #{scaffold.name}/ with:"
  puts "  #{scaffold.name}/workflow.yml"
  puts "  #{scaffold.name}/extractor.rb"
  puts "  #{scaffold.name}/normalizer.rb"
  puts "  #{scaffold.name}/test/#{scaffold.name}_extract_credentials_test.rb"
  puts "  #{scaffold.name}/test/#{scaffold.name}_normalizer_test.rb"
  puts ""
  puts "Next steps:"
  puts "  1. Get a screenshot of the login page from the user"
  puts "  2. Run: rake har[~/Downloads/#{scaffold.name}_login.har]"
  puts "  3. Edit workflow.yml selectors + endpoints based on HAR analysis"
  puts "  4. First live run: --through extract --dump-raw /tmp/#{scaffold.name}_raw.json"
  puts "  5. Iterate normalizer: --from-raw /tmp/#{scaffold.name}_raw.json"
  puts ""
  puts "See docs/provider-creation-playbook.md for the full procedure."
end

# --- HAR analysis ---

desc "Analyze a HAR file: rake har[path/to/file.har] or rake har[path,api.host.com]"
task :har, [:path, :host] do |_, args|
  path = args[:path]
  host = args[:host]
  abort "Usage: rake har[path/to/file.har] or rake har[path,api.host.com]" unless path

  expanded = File.expand_path(path)
  abort "File not found: #{expanded}" unless File.exist?(expanded)

  require "freentonic/providers/har_analyzer"
  analyzer = Freentonic::Providers::HarAnalyzer.new(expanded)
  puts analyzer.report(api_host: host)
end

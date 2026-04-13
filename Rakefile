require "rake/testtask"

# One test task per provider directory (ing/test/**, unicaja/test/**, ...).
# Running `rake test` runs them all; `rake test:ing` runs just ING's.
provider_dirs = Dir["*/test"].map { |d| File.dirname(d) }.reject { |d| d == "lib" }.sort

namespace :test do
  provider_dirs.each do |provider|
    Rake::TestTask.new(provider.to_sym) do |t|
      t.libs << "#{provider}"
      t.test_files = FileList["#{provider}/test/**/*_test.rb"]
      t.warning = false
      t.description = "Run tests for the #{provider} provider"
    end
  end

  desc "Run shared helper tests"
  Rake::TestTask.new(:helpers) do |t|
    t.libs << "lib"
    t.test_files = FileList["lib/test/**/*_test.rb"]
    t.warning = false
    t.description = "Run shared helper tests"
  end
end

desc "Run tests for every provider + shared helpers"
task test: provider_dirs.map { |p| "test:#{p}" } + ["test:helpers"]

task default: :test

# --- Scaffold a new provider ---

desc "Scaffold a new provider: rake new[provider_name]"
task :new, [:name] do |_, args|
  name = args[:name]
  abort "Usage: rake new[provider_name]" unless name && !name.empty?

  require_relative "lib/freentonic/providers/scaffold"
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

  require_relative "lib/freentonic/providers/har_analyzer"
  analyzer = Freentonic::Providers::HarAnalyzer.new(expanded)
  puts analyzer.report(api_host: host)
end

require "rake/testtask"

# One test task per provider directory (ing/test/**, unicaja/test/**, ...).
# Running `rake test` runs them all; `rake test:ing` runs just ING's.
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

source "https://rubygems.org"

# Point at a freentonic checkout during development. Override with
#   bundle config set --local local.freentonic /path/to/freentonic
# or edit this path if your checkout lives elsewhere.
gem "freentonic", path: File.expand_path("../freentonic", __dir__)

group :development, :test do
  gem "minitest", "~> 5.20"
  gem "rake", "~> 13.0"
  # Default gems that Bundler won't autoload unless declared (Ruby 3.4+).
  gem "base64"
  gem "csv"
end

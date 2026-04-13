require "fileutils"

module Freentonic
  module Providers
    class Scaffold
      attr_reader :name, :camel_name, :dir

      def initialize(name)
        @name = name.downcase.gsub(/[^a-z0-9_]/, "_")
        @camel_name = @name.split("_").map(&:capitalize).join
        @dir = File.expand_path(@name, Dir.pwd)
      end

      def generate!
        raise "Directory #{dir} already exists" if Dir.exist?(dir)

        FileUtils.mkdir_p(File.join(dir, "test"))

        write_workflow_yml
        write_extractor
        write_normalizer
        write_credential_test
        write_normalizer_test

        @name
      end

      private

      def write_workflow_yml
        File.write(File.join(dir, "workflow.yml"), <<~YAML)
          version: 1

          config:
            key: #{name}
            default_lookback_days: 90

          # Declare secrets the user must provide on first run.
          # Values are cached in the macOS Keychain after first entry.
          secrets:
            USER_EMAIL:
              prompt: "#{camel_name} email or username"
            USER_PASSWORD:
              prompt: "#{camel_name} password or passcode"

          pipeline:
            - connect
            - login
            - approve_2fa
            - post_login
            - capture_credentials

          phases:
            connect:
              - action: navigate
                url: "https://REPLACE_WITH_LOGIN_URL"
              # wait_network_idle handles all states: fresh login,
              # remembered credentials, or already logged in.
              - action: wait_network_idle
                seconds: 3

            login:
              # Use _if_present actions so already-logged-in is a no-op.
              # REPLACE selectors below after inspecting the actual page.
              # Rule: NEVER guess selectors — ask for a screenshot first.
              - action: fill_if_present
                selector: "input[type='email'], input[name='email']"
                value: "secret(USER_EMAIL)"
              - action: click_if_present
                selector: "button[type='submit']"
              - action: fill_if_present
                selector: "input[type='password']"
                value: "secret(USER_PASSWORD)"
              - action: click_if_present
                selector: "button[type='submit']"

            approve_2fa:
              # Wait for the post-login page. Use a SPECIFIC path, not
              # just the domain — broad matches can fire before 2FA completes.
              - action: wait_url
                includes: "REPLACE_WITH_POST_LOGIN_URL_PATH"
                timeout: 300

            post_login:
              - action: wait_network_idle
                seconds: 8

            capture_credentials:
              # Capture cookies first — they're the most common auth mechanism.
              # capture_cookie_header uses CDP and gets httpOnly cookies that
              # are invisible in HAR exports.
              - action: capture_cookie_header
                host: "REPLACE_WITH_API_HOST"
                path: "/api/"
                as: cookie
              # Add capture_header for any custom auth headers (x-csrf-token, etc.)
              # - action: capture_header
              #   name: "X-Custom-Header"
              #   as: custom_header
              #   retries: 5
              #   interval_seconds: 2

          credentials:
            require:
              - cookie
            validate:
              - key: cookie
                not_empty: true
            map:
              - { from: cookie, as: cookie }

          api_client:
            base_url: "https://REPLACE_WITH_API_HOST"
            api_root: "/REPLACE_WITH_API_ROOT"
            credentials: [cookie]
            auth_headers:
              Cookie: "{cookie}"
            batch_keys: []
            date_format: "%Y-%m-%d"
            endpoints:
              # Add endpoints discovered from HAR analysis.
              # Run: rake har[~/Downloads/#{name}_login.har]
              - name: fetch_accounts
                method: GET
                path: "/accounts"
              # - name: fetch_transactions_page
              #   method: GET
              #   path: "/transactions"
              #   params:
              #     count: 50
              #     offset: "{offset}"

          extract:
            ruby: ./extractor.rb
            class: Freentonic::Providers::#{camel_name}::Extractor

          normalize:
            ruby: ./normalizer.rb
            class: Freentonic::Providers::#{camel_name}::Normalizer
        YAML
      end

      def write_extractor
        File.write(File.join(dir, "extractor.rb"), <<~RUBY)
          require_relative "../lib/freentonic/providers/helpers"

          module Freentonic
            module Providers
              module #{camel_name}
                class Extractor
                  include Freentonic::Providers::Helpers

                  MAX_TRANSACTIONS_SAFETY_CAP = 10_000

                  def call(client:, credentials:, from_date:, stdout:, stderr:)
                    # 1. Fetch accounts / products
                    stdout.puts "  Fetching accounts..."
                    accounts = client.fetch_accounts
                    stdout.puts "    → \#{Array(accounts).size} accounts"

                    # 2. Fetch movements per account
                    accounts.each do |account|
                      id = account["id"]
                      label = account["name"] || id
                      stdout.puts "  Fetching movements for \#{label}..."
                      begin
                        account["movements"] = [] # TODO: implement fetch
                        stdout.puts "    → \#{account["movements"].size} movements"
                      rescue StandardError => error
                        stderr.puts "    ✗ \#{error.class}: \#{error.message}"
                        account["movements"] = []
                      end
                    end

                    accounts
                  end
                end
              end
            end
          end
        RUBY
      end

      def write_normalizer
        File.write(File.join(dir, "normalizer.rb"), <<~RUBY)
          require "date"
          require_relative "../lib/freentonic/providers/helpers"

          module Freentonic
            module Providers
              module #{camel_name}
                class Normalizer < Freentonic::Normalizers::Base
                  include Freentonic::Providers::Helpers

                  def call(raw, context: {})
                    {
                      "source_tag" => "#{name}_push",
                      "accounts"   => Array(raw).filter_map { |a| build_account(a) }
                    }
                  end

                  private

                  def build_account(a)
                    account_id = a["id"]
                    return nil unless account_id

                    {
                      "external_id"    => "#{name}_live:\#{account_id}",
                      "legacy_uids"    => ["#{name}_live:\#{account_id}"],
                      "iban"           => a["iban"],
                      "kind"           => "asset",
                      "bank_key"       => "#{name}",
                      "name"           => a["name"] || "#{camel_name} \#{account_id}",
                      "currency"       => a["currency"] || "EUR",
                      "balance_cents"  => cents(a["balance"]),
                      "balance_source" => "#{name}_live:accounts",
                      "metadata"       => { "#{name}_account_id" => account_id },
                      "movements"      => Array(a["movements"]).filter_map { |mv| build_movement(account_id, mv) }
                    }
                  end

                  def build_movement(account_id, mv)
                    mv_id = mv["id"]
                    return nil unless mv_id

                    amount = cents(mv["amount"])
                    return nil unless amount && amount != 0

                    date = parse_date(mv["date"] || mv["startedDate"] || mv["completedDate"])
                    return nil unless date

                    {
                      "dedup_key"    => "#{name}_live:\#{account_id}:\#{mv_id}",
                      "date"         => date.strftime("%Y-%m-%d"),
                      "amount_cents" => amount,
                      "currency"     => mv["currency"] || "EUR",
                      "description"  => (mv["description"] || mv["type"]).to_s.strip,
                      "raw_payload"  => { "#{name}_movement" => mv }
                    }
                  end
                end
              end
            end
          end
        RUBY
      end

      def write_credential_test
        File.write(File.join(dir, "test", "#{name}_extract_credentials_test.rb"), <<~RUBY)
          require "minitest/autorun"
          require "stringio"
          require "freentonic"

          class #{camel_name}ExtractCredentialsTest < Minitest::Test
            WORKFLOW_PATH = File.expand_path("../workflow.yml", __dir__)

            def source
              Freentonic::Source.new(workflow_path: WORKFLOW_PATH)
            end

            def test_maps_captured_context_to_credentials
              credentials = source.extract_credentials(
                nil,
                workflow_context: {
                  "cookie" => "session=abc123"
                },
                stdout: StringIO.new,
                stderr: StringIO.new
              )

              assert_equal({ cookie: "session=abc123" }, credentials)
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
        RUBY
      end

      def write_normalizer_test
        File.write(File.join(dir, "test", "#{name}_normalizer_test.rb"), <<~RUBY)
          require "minitest/autorun"
          require "freentonic"
          require_relative "../normalizer"

          class #{camel_name}NormalizerTest < Minitest::Test
            def normalizer
              Freentonic::Providers::#{camel_name}::Normalizer.new
            end

            def test_normalizes_account_with_movements
              raw = [
                {
                  "id"       => "acc-1",
                  "name"     => "Main Account",
                  "iban"     => "XX00 1234 5678 9012",
                  "currency" => "EUR",
                  "balance"  => 1234.56,
                  "movements" => [
                    {
                      "id"          => "mv-1",
                      "date"        => "2024-03-15",
                      "amount"      => -12.34,
                      "currency"    => "EUR",
                      "description" => "Test payment"
                    }
                  ]
                }
              ]

              payload = normalizer.call(raw)

              assert_equal "#{name}_push", payload["source_tag"]
              assert_equal 1, payload["accounts"].size

              acct = payload["accounts"].first
              assert_equal "#{name}_live:acc-1", acct["external_id"]
              assert_equal "asset", acct["kind"]

              mv = acct["movements"].first
              assert_equal "#{name}_live:acc-1:mv-1", mv["dedup_key"]
              assert_equal(-1234, mv["amount_cents"])
            end

            def test_skips_movements_with_nil_amount
              raw = [
                {
                  "id" => "acc-1", "currency" => "EUR", "balance" => 0,
                  "movements" => [
                    { "id" => "mv-ok", "date" => "2024-03-15", "amount" => -5.0, "description" => "Valid" },
                    { "id" => "mv-nil", "date" => "2024-03-15", "amount" => nil, "description" => "Skip" }
                  ]
                }
              ]

              payload = normalizer.call(raw)
              assert_equal 1, payload["accounts"].first["movements"].size
            end
          end
        RUBY
      end
    end
  end
end

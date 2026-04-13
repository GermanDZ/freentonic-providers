require "json"
require "uri"

module Freentonic
  module Providers
    class HarAnalyzer
      attr_reader :entries

      def initialize(har_path)
        raw = JSON.parse(File.read(File.expand_path(har_path)))
        @entries = raw["log"]["entries"]
      end

      # List unique API endpoints (method + path, no query string).
      # Filter to a specific host if provided.
      def api_endpoints(host: nil)
        filtered = host ? entries.select { |e| e["request"]["url"].include?(host) } : entries
        filtered
          .select { |e| e["request"]["url"].include?("/api/") }
          .map { |e|
            url = e["request"]["url"].gsub(/\?.*/, "")
            method = e["request"]["method"]
            status = e["response"]["status"]
            # Generalize UUIDs in paths
            path = URI.parse(url).path.gsub(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i, "{id}")
            { method: method, path: path, status: status, url: url }
          }
          .uniq { |e| [e[:method], e[:path]] }
          .reject { |e| e[:method] == "HEAD" || e[:method] == "OPTIONS" }
      end

      # List custom/auth headers on API calls, ranked by frequency.
      BROWSER_HEADERS = %w[
        accept accept-encoding accept-language sec-ch-ua sec-ch-ua-mobile
        sec-ch-ua-platform sec-fetch-dest sec-fetch-mode sec-fetch-site
        user-agent priority :authority :method :path :scheme cache-control
        pragma content-length content-type origin referer
      ].freeze

      def auth_headers(host: nil)
        filtered = host ? entries.select { |e| e["request"]["url"].include?(host) } : entries
        api = filtered.select { |e| e["request"]["url"].include?("/api/") }
        api
          .flat_map { |e| e["request"]["headers"].map { |h| h["name"] } }
          .reject { |name| BROWSER_HEADERS.include?(name.downcase) }
          .tally
          .sort_by { |_, n| -n }
      end

      # Analyze login/signin POST requests — show keys, not values.
      def login_flow
        signin = entries.select { |e|
          url = e["request"]["url"].downcase
          e["request"]["method"] == "POST" &&
            (url.include?("/signin") || url.include?("/login") || url.include?("/auth"))
        }

        signin.map { |e|
          post_data = e.dig("request", "postData", "text")
          keys = begin
            JSON.parse(post_data).keys
          rescue
            nil
          end

          {
            url: e["request"]["url"].gsub(/\?.*/, ""),
            status: e["response"]["status"],
            keys: keys,
            timestamp: e["startedDateTime"]
          }
        }
      end

      # Detect pagination patterns from transaction/movement endpoints.
      def pagination_patterns
        txn_entries = entries.select { |e|
          url = e["request"]["url"]
          e["request"]["method"] == "GET" &&
            (url.include?("transaction") || url.include?("movement") || url.include?("operations"))
        }

        txn_entries.map { |e|
          url = e["request"]["url"]
          params = url.include?("?") ? URI.decode_www_form(url.split("?", 2).last) : []
          { url: url.gsub(/\?.*/, ""), params: params.to_h }
        }
      end

      # Check if response content was captured.
      def has_response_content?
        api = entries.select { |e| e["request"]["url"].include?("/api/") && e["response"]["status"] == 200 }
        return false if api.empty?
        api.any? { |e| (e.dig("response", "content", "text")&.length || 0) > 0 }
      end

      # Generate a human-readable report.
      def report(api_host: nil)
        lines = []
        lines << "# HAR Analysis Report"
        lines << ""
        lines << "Entries: #{entries.size}"
        lines << "Response content captured: #{has_response_content? ? "yes" : "NO — re-capture with 'Save all as HAR with content'"}"
        lines << ""

        # API endpoints
        endpoints = api_endpoints(host: api_host)
        lines << "## API Endpoints (#{endpoints.size} unique)"
        lines << ""
        endpoints.each { |e| lines << "  #{e[:method]} #{e[:status]} #{e[:path]}" }
        lines << ""

        # Auth headers
        headers = auth_headers(host: api_host)
        lines << "## Custom Headers on API Calls"
        lines << ""
        headers.first(15).each { |name, count| lines << "  %3d  %s" % [count, name] }
        lines << ""

        # Login flow
        login = login_flow
        if login.any?
          lines << "## Login Flow (#{login.size} POST requests)"
          lines << ""
          login.each_with_index { |l, i|
            keys_str = l[:keys] ? l[:keys].join(", ") : "(not JSON)"
            lines << "  ##{i + 1} #{l[:status]} #{l[:url].split("/").last(3).join("/")} — keys: #{keys_str}"
          }
          lines << ""
        end

        # Pagination
        pagination = pagination_patterns
        if pagination.any?
          lines << "## Pagination Patterns (#{pagination.size} transaction requests)"
          lines << ""
          pagination.each_with_index { |p, i|
            lines << "  ##{i + 1} params: #{p[:params].map { |k, v| "#{k}=#{v[0..20]}" }.join(", ")}"
          }
          lines << ""
        end

        lines.join("\n")
      end
    end
  end
end

require "date"
require "time"

module Freentonic
  module Providers
    module Helpers
      # Wrap a non-critical fetch so one failing product doesn't sink
      # the whole run. Returns nil on error.
      #
      #   bank_details = safe_fetch(stderr, "bank details") { client.fetch_bank_details }
      #
      def safe_fetch(stderr, label)
        yield
      rescue StandardError => error
        stderr.puts "    ✗ #{label}: #{error.class}: #{error.message}"
        nil
      end

      # Convert an amount to integer cents. Handles the formats seen
      # across providers:
      #
      #   cents(12.34)                              #=> 1234   (major units → cents)
      #   cents(1234, already_minor: true)          #=> 1234   (already cents)
      #   cents({"amount" => 12.34})                #=> 1234   (Hash with amount key)
      #   cents("12,34")                            #=> 1234   (String with comma)
      #   cents(nil)                                #=> nil
      #
      def cents(amount, already_minor: false)
        return nil if amount.nil?

        case amount
        when Hash
          value = (amount["amount"] || amount["value"] || amount["cantidad"] || amount["importe"])&.to_f
          value ? (value * 100).round : nil
        when Numeric
          already_minor ? amount.to_i : (amount.to_f * 100).round
        when String
          (amount.tr(",", ".").to_f * 100).round
        end
      end

      # Parse a date from various formats seen across providers.
      # Returns a Date or nil.
      #
      #   parse_date(1710504000000)                  #=> Date (Unix ms)
      #   parse_date("2024-03-15T10:00:00.000Z")    #=> Date (ISO 8601)
      #   parse_date("15/03/2024")                   #=> Date (DD/MM/YYYY)
      #   parse_date("2024-03-15")                   #=> Date (YYYY-MM-DD)
      #   parse_date(nil)                            #=> nil
      #
      def parse_date(value)
        return nil if value.nil?

        case value
        when Date
          value
        when Numeric
          # Unix timestamp — detect seconds vs milliseconds.
          # Timestamps after year 3000 in seconds (~32503680000) are
          # implausible, so anything above 10^12 is milliseconds.
          ts = value > 1_000_000_000_000 ? value / 1000.0 : value.to_f
          Time.at(ts).to_date
        when String
          if value =~ /\A\d{10,13}\z/
            # Numeric string (Unix timestamp)
            ts = value.to_i
            ts = ts / 1000 if ts > 1_000_000_000_000
            Time.at(ts).to_date
          else
            Date.parse(value)
          end
        end
      rescue ArgumentError, TypeError
        # Fallback: try DD/MM/YYYY
        begin
          Date.strptime(value.to_s, "%d/%m/%Y")
        rescue Date::Error, ArgumentError
          nil
        end
      end

      # Parse a value to a Unix millisecond timestamp. Useful for
      # cursor-based pagination where the API expects ms timestamps.
      #
      #   parse_timestamp_ms(1710504000000)                  #=> 1710504000000
      #   parse_timestamp_ms("2024-03-15T10:00:00.000Z")    #=> 1710504000000
      #
      def parse_timestamp_ms(value)
        case value
        when Numeric
          value > 1_000_000_000_000 ? value.to_i : (value * 1000).to_i
        when String
          if value =~ /\A\d+\z/
            v = value.to_i
            v > 1_000_000_000_000 ? v : v * 1000
          else
            (Time.parse(value).to_f * 1000).to_i
          end
        end
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end

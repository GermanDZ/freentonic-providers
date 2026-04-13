require "minitest/autorun"
require "stringio"
require_relative "../freentonic/providers/helpers"

class HelpersTest < Minitest::Test
  include Freentonic::Providers::Helpers

  # --- safe_fetch ---

  def test_safe_fetch_returns_result_on_success
    stderr = StringIO.new
    result = safe_fetch(stderr, "test") { 42 }
    assert_equal 42, result
    assert_empty stderr.string
  end

  def test_safe_fetch_returns_nil_on_error
    stderr = StringIO.new
    result = safe_fetch(stderr, "bank details") { raise "boom" }
    assert_nil result
    assert_includes stderr.string, "bank details"
    assert_includes stderr.string, "RuntimeError"
  end

  # --- cents ---

  def test_cents_from_major_units
    assert_equal 1234, cents(12.34)
    assert_equal(-567, cents(-5.67))
    assert_equal 100, cents(1.0)
  end

  def test_cents_already_minor
    assert_equal 1234, cents(1234, already_minor: true)
    assert_equal(-567, cents(-567, already_minor: true))
  end

  def test_cents_from_hash
    assert_equal 1234, cents({"amount" => 12.34})
    assert_equal 500, cents({"value" => 5.0})
    assert_equal 999, cents({"cantidad" => 9.99})
  end

  def test_cents_from_string
    assert_equal 1234, cents("12.34")
    assert_equal 1234, cents("12,34")
  end

  def test_cents_nil
    assert_nil cents(nil)
  end

  def test_cents_hash_with_nil_value
    assert_nil cents({"amount" => nil})
  end

  # --- parse_date ---

  def test_parse_date_unix_ms
    # 2024-03-15 ~12:00 UTC
    date = parse_date(1710504000000)
    assert_equal 2024, date.year
    assert_equal 3, date.month
    assert_equal 15, date.day
  end

  def test_parse_date_unix_seconds
    date = parse_date(1710504000)
    assert_equal 2024, date.year
    assert_equal 3, date.month
  end

  def test_parse_date_iso_string
    date = parse_date("2024-03-15T10:00:00.000Z")
    assert_equal Date.new(2024, 3, 15), date
  end

  def test_parse_date_yyyy_mm_dd
    date = parse_date("2024-03-15")
    assert_equal Date.new(2024, 3, 15), date
  end

  def test_parse_date_dd_mm_yyyy
    date = parse_date("15/03/2024")
    assert_equal Date.new(2024, 3, 15), date
  end

  def test_parse_date_nil
    assert_nil parse_date(nil)
  end

  def test_parse_date_garbage
    assert_nil parse_date("not a date")
  end

  def test_parse_date_numeric_string_ms
    date = parse_date("1710504000000")
    assert_equal 2024, date.year
  end

  # --- parse_timestamp_ms ---

  def test_parse_timestamp_ms_from_integer_ms
    assert_equal 1710504000000, parse_timestamp_ms(1710504000000)
  end

  def test_parse_timestamp_ms_from_integer_seconds
    assert_equal 1710504000000, parse_timestamp_ms(1710504000)
  end

  def test_parse_timestamp_ms_from_iso_string
    ts = parse_timestamp_ms("2024-03-15T12:00:00.000Z")
    assert_in_delta 1710504000000, ts, 1000
  end

  def test_parse_timestamp_ms_nil
    assert_nil parse_timestamp_ms(nil)
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "date"
require_relative "../extractor"

# Exercises the cursor-pagination loop in the Unicaja extractor against
# a FakeClient. The busqueda endpoint returns full response hashes with
# `movimientos` + `masMovimientos`; pagination cursors come from
# masMovimientos (not from the last row).
class UnicajaExtractorPaginationTest < Minitest::Test
  def build_row(idx, saldo)
    {
      "fechaOperacion" => "2025-06-01",
      "concepto" => "row #{idx}",
      "numMovimiento" => idx.to_s,
      "importeMovimiento" => { "cantidad" => -100.0, "moneda" => "EUR" },
      "saldo" => { "cantidad" => saldo, "moneda" => "EUR" }
    }
  end

  def build_response(first_idx, size, saldo_start, more: true)
    movimientos = Array.new(size) { |i| build_row(first_idx + i, saldo_start - i) }
    last_idx = first_idx + size - 1
    last_saldo = saldo_start - (size - 1)
    {
      "movimientos" => movimientos,
      "masMovimientos" => {
        "numUltimoMovimiento" => more ? last_idx.to_s : "",
        "indMasMovimientos" => more ? "S" : "N",
        "ultimoSaldo" => more ? { "cantidad" => last_saldo, "moneda" => "EUR" } : {},
        "indOTP" => "N"
      }
    }
  end

  class FakeClient
    attr_reader :extended_calls

    def initialize(extended_pages, standard_movements: [])
      @extended_pages = extended_pages
      @standard_movements = standard_movements
      @extended_calls = []
    end

    def fetch_account_movements_page(**kwargs)
      @extended_calls << kwargs
      @extended_pages.shift
    end

    def fetch_all_account_movements(**_kwargs)
      @standard_movements
    end

    def fetch_listacuentas;   { "cuentas"   => [{ "ppp" => "001" }] }; end
    def fetch_listatarjetas;  { "tarjetas"  => [] }; end
    def fetch_listaprestamos; { "prestamos" => [] }; end
    def fetch_all_card_movements(**); []; end
  end

  def run_extract(extended_pages, from_date: Date.new(2025, 1, 1), standard_movements: [])
    client = FakeClient.new(extended_pages, standard_movements: standard_movements)
    stdout = StringIO.new
    stderr = StringIO.new
    result = Freentonic::Providers::Unicaja::Extractor.new.call(
      client:      client,
      credentials: {},
      from_date:   from_date,
      stdout:      stdout,
      stderr:      stderr
    )
    [result, client, stdout, stderr]
  end

  def test_paginates_using_mas_movimientos_until_no_more
    pages = [
      build_response(1,  20, 2000.00, more: true),
      build_response(21, 20, 1500.00, more: true),
      build_response(41,  5, 1200.00, more: false)
    ]

    result, client, _stdout, _stderr = run_extract(pages)

    movements = result.fetch("cuenta_movements").fetch("001")
    assert_equal 45, movements.size
    assert_equal "1",  movements.first["numMovimiento"]
    assert_equal "45", movements.last["numMovimiento"]

    # 3 calls total — stops when indMasMovimientos is "N".
    assert_equal 3, client.extended_calls.size
  end

  def test_cursor_values_come_from_mas_movimientos
    pages = [
      build_response(1,  20, 2000.00, more: true),
      build_response(21, 20, 1500.00, more: true),
      build_response(41,  5, 1200.00, more: false)
    ]

    _result, client, _stdout, _stderr = run_extract(pages)

    # First call: indOperacion="I", no cursor.
    assert_equal "I", client.extended_calls[0][:ind_operacion]
    assert_nil client.extended_calls[0][:saldo_ult_mov]
    assert_nil client.extended_calls[0][:num_ult_mov]

    # Second call: cursor from masMovimientos of page 1.
    assert_equal "P", client.extended_calls[1][:ind_operacion]
    assert_equal "20",  client.extended_calls[1][:num_ult_mov]
    assert_equal 1981.0, client.extended_calls[1][:saldo_ult_mov]

    # Third call: cursor from masMovimientos of page 2.
    assert_equal "P", client.extended_calls[2][:ind_operacion]
    assert_equal "40",  client.extended_calls[2][:num_ult_mov]
    assert_equal 1481.0, client.extended_calls[2][:saldo_ult_mov]
  end

  def test_merges_and_deduplicates_standard_and_extended
    standard = [
      build_row(44, 1100.0),
      build_row(45, 1050.0),
      build_row(46, 1000.0)
    ]
    extended_pages = [
      build_response(41, 5, 1200.00, more: false)
    ]

    result, _client, _stdout, _stderr = run_extract(
      extended_pages,
      standard_movements: standard
    )

    movements = result.fetch("cuenta_movements").fetch("001")
    ids = movements.map { |m| m["numMovimiento"] }

    # Extended has 41-45, standard has 44-46.
    # Dedup keeps 41-46 (6 unique).
    assert_equal 6, movements.size
    assert_equal %w[41 42 43 44 45 46], ids.sort_by(&:to_i)
  end

  def test_standard_only_when_within_30_days
    result, client, _stdout, _stderr = run_extract(
      [], # no extended pages needed
      from_date: Date.today - 10,
      standard_movements: [build_row(1, 500.0)]
    )

    movements = result.fetch("cuenta_movements").fetch("001")
    assert_equal 1, movements.size

    # No extended calls made.
    assert_empty client.extended_calls
  end

  def test_safety_cap_stops_pagination
    # Return pages indefinitely with more=true
    infinite_pages = Array.new(200) do |page_num|
      build_response(page_num * 100 + 1, 100, 9999.0 - page_num, more: true)
    end

    stdout = StringIO.new
    client = FakeClient.new(infinite_pages)
    result = Freentonic::Providers::Unicaja::Extractor.new.call(
      client:      client,
      credentials: {},
      from_date:   Date.new(2025, 1, 1),
      stdout:      stdout,
      stderr:      StringIO.new
    )

    movements = result.fetch("cuenta_movements").fetch("001")
    cap = Freentonic::Providers::Unicaja::Extractor::MAX_MOVEMENTS_SAFETY_CAP
    assert movements.size >= cap, "expected >= #{cap}, got #{movements.size}"
    assert movements.size <= cap + 100
    assert_includes stdout.string, "MAX_MOVEMENTS_SAFETY_CAP"
  end

  def test_nil_response_terminates_gracefully
    pages = [nil]

    result, _client, _stdout, _stderr = run_extract(pages)

    movements = result.fetch("cuenta_movements").fetch("001")
    assert_equal 0, movements.size
  end

  def test_extended_failure_falls_back_to_standard
    # FakeClient that raises on extended fetch
    error_client = Class.new do
      def fetch_account_movements_page(**) raise "server error"; end
      def fetch_all_account_movements(**) [{ "numMovimiento" => "1", "fechaOperacion" => "2025-06-01", "importe" => 100 }]; end
      def fetch_listacuentas;   { "cuentas" => [{ "ppp" => "001" }] }; end
      def fetch_listatarjetas;  { "tarjetas" => [] }; end
      def fetch_listaprestamos; { "prestamos" => [] }; end
      def fetch_all_card_movements(**); []; end
    end.new

    stderr = StringIO.new
    result = Freentonic::Providers::Unicaja::Extractor.new.call(
      client:      error_client,
      credentials: {},
      from_date:   Date.new(2025, 1, 1),
      stdout:      StringIO.new,
      stderr:      stderr
    )

    movements = result.fetch("cuenta_movements").fetch("001")
    assert_equal 1, movements.size
    assert_includes stderr.string, "extended fetch failed"
  end
end

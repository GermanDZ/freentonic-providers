# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "date"
require_relative "../extractor"

# Exercises the Unicaja extractor's per-cuenta merge + skip logic.
#
# Cursor pagination for the busqueda endpoint now lives in the freentonic
# framework (declared in unicaja/workflow.yml via `pagination: cursor`,
# walked by ApiClient#ep_paginate_by_cursor). The framework's tests cover
# the loop's correctness across all flavors (initial vs. continue kwargs,
# missing cursor → stop, continue_when → stop, safety cap). What stays
# here is the provider-specific behavior: extended ↔ standard merge,
# dedup across field-name variants, debit-card skip, extended-fetch
# failure fallback.
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

  # Stand-in for the framework's auto-generated api_client. The
  # cursor-pagination loop is the framework's concern; from the
  # extractor's POV `fetch_extended_account_movements` returns the
  # already-flattened Array of rows in one call.
  class FakeClient
    attr_reader :extended_calls

    def initialize(extended_movements, standard_movements: [])
      @extended_movements = extended_movements
      @standard_movements = standard_movements
      @extended_calls = []
    end

    def fetch_extended_account_movements(**kwargs)
      @extended_calls << kwargs
      @extended_movements
    end

    def fetch_all_account_movements(**_kwargs)
      @standard_movements
    end

    def fetch_listacuentas;   { "cuentas"   => [{ "ppp" => "001" }] }; end
    def fetch_listatarjetas;  { "tarjetas"  => [] }; end
    def fetch_listaprestamos; { "prestamos" => [] }; end
    def fetch_all_card_movements(**); []; end
  end

  def run_extract(extended_movements, from_date: Date.new(2025, 1, 1), standard_movements: [])
    client = FakeClient.new(extended_movements, standard_movements: standard_movements)
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

  def test_extended_call_receives_only_orchestration_kwargs
    # Cursor kwargs (ind_operacion / saldo_ult_mov / num_ult_mov) are
    # managed by the framework's pagination loop, not by the extractor.
    # Verify the extractor passes only what's orthogonal to pagination.
    _result, client, _stdout, _stderr = run_extract([build_row(1, 100.0)])

    assert_equal 1, client.extended_calls.size
    call = client.extended_calls.first
    assert_equal "001", call[:ppp]
    assert call.key?(:fecha_desde)
    assert call.key?(:fecha_hasta)
    refute call.key?(:ind_operacion)
    refute call.key?(:saldo_ult_mov)
    refute call.key?(:num_ult_mov)
  end

  # Regression: Unicaja's standard /cuentas/movimientos endpoint stamps
  # the per-account sequence number on a row as `nummov`, while the
  # extended /apis/externo/.../busqueda endpoint uses `numMovimiento`
  # for the same field. A row that appears in BOTH responses (the
  # standard window overlaps the tail of the extended window) must
  # collapse to one entry, regardless of which field name carries the
  # sequence. Before this fix the dedup only checked `numMovimiento`;
  # standard-endpoint rows had it nil and slipped through as
  # "no-key, keep unconditionally", producing two canonical txns that
  # hashed to the same id and surfaced as visible duplicates in the
  # consolidated SimpleFIN envelope.
  def test_merge_dedupes_across_nummov_and_numMovimiento_field_naming
    extended = [build_row(40, 1300.0), build_row(41, 1200.0), build_row(42, 1100.0)]
    # Standard endpoint: row 42 appears here under `nummov`. Row 43 is
    # new (only in the standard window).
    standard = [
      { "fechaoper" => "2025-06-01", "concepto" => "row 42",
        "nummov" => "42",
        "importe" => { "cantidad" => -100.0, "moneda" => "EUR" } },
      { "fechaoper" => "2025-06-01", "concepto" => "row 43",
        "nummov" => "43",
        "importe" => { "cantidad" => -100.0, "moneda" => "EUR" } }
    ]

    result, _client, _stdout, _stderr = run_extract(extended, standard_movements: standard)

    movements = result.fetch("cuenta_movements").fetch("001")
    # Expect 4 unique (40, 41, 42, 43) — NOT 5 (the row-42 dupe must
    # collapse even though the two copies have different field names).
    assert_equal 4, movements.size
    keys = movements.map { |m| m["numMovimiento"] || m["nummov"] }
    assert_equal %w[40 41 42 43], keys.sort_by(&:to_i)
  end

  def test_merges_and_deduplicates_standard_and_extended
    standard = [
      build_row(44, 1100.0),
      build_row(45, 1050.0),
      build_row(46, 1000.0)
    ]
    extended = (41..45).map { |i| build_row(i, 1200.0 - i) }

    result, _client, _stdout, _stderr = run_extract(extended, standard_movements: standard)

    movements = result.fetch("cuenta_movements").fetch("001")
    ids = movements.map { |m| m["numMovimiento"] }

    # Extended has 41-45, standard has 44-46. Dedup keeps 41-46.
    assert_equal 6, movements.size
    assert_equal %w[41 42 43 44 45 46], ids.sort_by(&:to_i)
  end

  def test_standard_only_when_within_30_days
    result, client, _stdout, _stderr = run_extract(
      [], # no extended needed
      from_date: Date.today - 10,
      standard_movements: [build_row(1, 500.0)]
    )

    movements = result.fetch("cuenta_movements").fetch("001")
    assert_equal 1, movements.size

    # No extended calls made.
    assert_empty client.extended_calls
  end

  def test_extended_failure_falls_back_to_standard
    # Client that raises on the extended call — exercises the
    # safe_fetch boundary in the extractor.
    error_client = Class.new do
      def fetch_extended_account_movements(**) raise "server error"; end
      def fetch_all_account_movements(**)
        [{ "numMovimiento" => "1", "fechaOperacion" => "2025-06-01", "importe" => 100 }]
      end
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

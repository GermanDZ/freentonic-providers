# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "date"
require "freentonic"

# Exercises unicaja/workflow.yml's `extract: plan:` orchestration — the
# zero-Ruby replacement for the old extractor.rb.
#
# Cursor pagination for the busqueda endpoint lives in the freentonic
# framework (declared via `pagination: cursor`, walked by
# ApiClient#ep_paginate_by_cursor; the framework's tests cover the loop).
# From the plan's POV `fetch_extended_account_movements` returns the
# already-flattened Array of rows in one call. What stays here is the
# provider-specific behavior the plan now owns declaratively: the
# extended↔standard merge, the cross-field-spelling dedup, the >30-day
# extended gate, and the extended-fetch failure fallback.
class UnicajaExtractPlanTest < Minitest::Test
  WORKFLOW = File.expand_path("../workflow.yml", __dir__)

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
  # cursor-pagination loop is the framework's concern; from the plan's POV
  # `fetch_extended_account_movements` returns the already-flattened Array.
  class FakeClient
    attr_reader :extended_calls

    def initialize(extended_movements, standard_movements: [], raise_extended: false)
      @extended_movements = extended_movements
      @standard_movements = standard_movements
      @raise_extended     = raise_extended
      @extended_calls     = []
    end

    def fetch_extended_account_movements(**kwargs)
      @extended_calls << kwargs
      raise "server error" if @raise_extended
      @extended_movements
    end

    def fetch_all_account_movements(**_kwargs) = @standard_movements
    def fetch_listacuentas   = { "cuentas"   => [{ "ppp" => "001" }] }
    def fetch_listatarjetas  = { "tarjetas"  => [] }
    def fetch_listaprestamos = { "prestamos" => [] }
    def fetch_all_card_movements(**) = []
  end

  def plan
    Freentonic::WorkflowSchema.load(WORKFLOW).raw.fetch("extract").fetch("plan")
  end

  def run_plan(client, from_date: Date.new(2025, 1, 1))
    schema    = Freentonic::WorkflowSchema.load(WORKFLOW)
    extractor = Freentonic::ExtractPlan::PlanExtractor.new(
      plan, endpoint_names: schema.api_client_endpoint_names
    )
    stderr = StringIO.new
    result = extractor.call(client: client, credentials: {}, from_date: from_date,
                            stdout: StringIO.new, stderr: stderr)
    [result, stderr]
  end

  def movements_for(result, ppp = "001")
    result.fetch("cuenta_movements").fetch(ppp)
  end

  def test_extended_call_receives_only_orchestration_kwargs
    # Cursor kwargs (ind_operacion / saldo_ult_mov / num_ult_mov) are
    # managed by the framework's pagination loop, not the plan. Verify the
    # plan passes only what's orthogonal to pagination.
    client = FakeClient.new([build_row(1, 100.0)])
    run_plan(client)

    assert_equal 1, client.extended_calls.size
    call = client.extended_calls.first
    assert_equal "001", call[:ppp]
    assert call.key?(:fecha_desde)
    assert call.key?(:fecha_hasta)
    refute call.key?(:ind_operacion)
    refute call.key?(:saldo_ult_mov)
    refute call.key?(:num_ult_mov)
  end

  # Regression: the standard /cuentas/movimientos endpoint stamps the
  # per-account sequence on a row as `nummov`, while the extended
  # /apis/externo/.../busqueda endpoint uses `numMovimiento` for the same
  # field. A row that appears in BOTH responses must collapse to one entry
  # regardless of which field carries the sequence — this is the
  # dedup_by: [numMovimiento, nummov] fallback-key behavior.
  def test_merge_dedupes_across_nummov_and_numMovimiento_field_naming
    extended = [build_row(40, 1300.0), build_row(41, 1200.0), build_row(42, 1100.0)]
    standard = [
      { "fechaoper" => "2025-06-01", "concepto" => "row 42",
        "nummov" => "42", "importe" => { "cantidad" => -100.0, "moneda" => "EUR" } },
      { "fechaoper" => "2025-06-01", "concepto" => "row 43",
        "nummov" => "43", "importe" => { "cantidad" => -100.0, "moneda" => "EUR" } }
    ]

    result, = run_plan(FakeClient.new(extended, standard_movements: standard))
    movements = movements_for(result)

    assert_equal 4, movements.size
    keys = movements.map { |m| m["numMovimiento"] || m["nummov"] }
    assert_equal %w[40 41 42 43], keys.sort_by(&:to_i)
  end

  def test_merges_and_deduplicates_standard_and_extended
    standard = [build_row(44, 1100.0), build_row(45, 1050.0), build_row(46, 1000.0)]
    extended = (41..45).map { |i| build_row(i, 1200.0 - i) }

    result, = run_plan(FakeClient.new(extended, standard_movements: standard))
    ids = movements_for(result).map { |m| m["numMovimiento"] }

    assert_equal 6, movements_for(result).size
    assert_equal %w[41 42 43 44 45 46], ids.sort_by(&:to_i)
  end

  def test_standard_only_when_within_30_days
    client = FakeClient.new([], standard_movements: [build_row(1, 500.0)])
    result, = run_plan(client, from_date: Date.today - 10)

    assert_equal 1, movements_for(result).size
    # The extended fetch is gated on lookback_days > 30 → never called.
    assert_empty client.extended_calls
  end

  def test_extended_failure_falls_back_to_standard
    # from_date well over 30 days ago → extended gate open; the fetch
    # raises but safe: default: [] degrades it, leaving the standard rows.
    client = FakeClient.new(nil, standard_movements: [build_row(1, 500.0)], raise_extended: true)
    result, stderr = run_plan(client, from_date: Date.new(2025, 1, 1))

    assert_equal 1, movements_for(result).size
    refute_empty client.extended_calls
    assert_includes stderr.string, "fetch_extended_account_movements"
  end
end

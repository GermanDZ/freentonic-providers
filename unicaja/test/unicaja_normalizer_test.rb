# frozen_string_literal: true

require "minitest/autorun"
require "bigdecimal"
require "freentonic"
require_relative "../normalizer"

class UnicajaNormalizerTest < Minitest::Test
  def normalizer
    Freentonic::Providers::Unicaja::Normalizer.new
  end

  def cuenta(overrides = {})
    {
      "ppp"         => "C-001",
      "alias"       => "Cuenta corriente",
      "iban"        => "ES1121000001234567890",
      "divisa"      => "EUR",
      "saldo"       => { "cantidad" => 1234.56, "moneda" => "EUR" }
    }.merge(overrides)
  end

  def tarjeta(overrides = {})
    {
      "ppp"         => "T-001",
      "alias"       => "Visa Credito",
      "divisa"      => "EUR",
      "codtipotarjeta" => "2",
      "tipotarjeta" => "Credit",
      "limite"      => { "cantidad" => 1500.00 },
      "disponible"  => { "cantidad" => 1000.00 }
    }.merge(overrides)
  end

  def prestamo(overrides = {})
    {
      "ppp"         => "P-001",
      "alias"       => "Hipoteca",
      "descripcion" => "Préstamo hipotecario",
      "indPrestamoHipotecario" => "S",
      "saldo"       => { "cantidad" => -125_000.00, "moneda" => "EUR" }
    }.merge(overrides)
  end

  def movement(overrides = {})
    {
      "numMovimiento"  => "M-1",
      "fechaOperacion" => "2024-03-15",
      "importe"        => { "cantidad" => -45.20, "divisa" => "EUR" },
      "concepto"       => "COFFEE SHOP"
    }.merge(overrides)
  end

  # --- envelope ----------------------------------------------------------

  def test_returns_canonical_payload_with_all_three_kinds
    raw = {
      "cuentas"   => [cuenta],
      "tarjetas"  => [tarjeta],
      "prestamos" => [prestamo],
      "cuenta_movements"  => { "C-001" => [movement] },
      "tarjeta_movements" => { "T-001" => [movement("numMovimiento" => "M-2", "concepto" => "RESTAURANT")] }
    }

    payload = normalizer.call(raw)

    assert_kind_of Freentonic::Canonical::CanonicalPayload, payload
    assert_equal "unicaja/0.2", payload.meta["scraper_version"]

    types = payload.accounts.map(&:type).sort
    assert_equal %w[checking credit_card loan], types
    # Tarjeta and prestamo each produce a Liability; cuenta does not.
    assert_equal 2, payload.liabilities.size
    assert_equal 2, payload.transactions.size
  end

  # --- cuenta ------------------------------------------------------------

  def test_cuenta_canonical_fields
    payload = normalizer.call({ "cuentas" => [cuenta] })
    acct = payload.accounts.first

    assert_equal "unicaja",       acct.institution
    assert_equal "checking",      acct.type
    assert_equal "cuenta:C-001",  acct.source_id
    assert_equal "ES1121000001234567890", acct.iban
    assert_equal BigDecimal("1234.56"),   acct.balance.current
  end

  # --- tarjeta (credit card) --------------------------------------------

  def test_tarjeta_emits_account_and_liability
    payload = normalizer.call({ "tarjetas" => [tarjeta] })

    assert_equal 1, payload.accounts.size
    acct = payload.accounts.first
    assert_equal "credit_card",   acct.type
    assert_equal "tarjeta:T-001", acct.source_id
    # Outstanding = limite - disponible = 1500 - 1000 = 500
    assert_equal BigDecimal("500.00"), acct.balance.current

    assert_equal 1, payload.liabilities.size
    liab = payload.liabilities.first
    assert_equal acct.id,             liab.account_id
    assert_equal "credit_card",       liab.type
    assert_equal BigDecimal("500.00"),  liab.balance
    assert_equal BigDecimal("1500.00"), liab.limit
  end

  def test_skips_non_credit_tarjetas
    debit = tarjeta("codtipotarjeta" => "1", "tipotarjeta" => "Debito", "descripcion" => "Debit card")
    payload = normalizer.call({ "tarjetas" => [debit] })
    assert_empty payload.accounts
  end

  # --- prestamo (loan / mortgage) ---------------------------------------

  def test_prestamo_emits_loan_account_and_liability
    payload = normalizer.call({ "prestamos" => [prestamo] })

    acct = payload.accounts.first
    assert_equal "loan",           acct.type
    assert_equal "prestamo:P-001", acct.source_id
    assert_equal BigDecimal("-125000.00"), acct.balance.current

    liab = payload.liabilities.first
    assert_equal acct.id,     liab.account_id
    # Hipotecario flag and description both trip detect_loan_type → "mortgage".
    assert_equal "mortgage",  liab.type
  end

  def test_non_mortgage_loan_detected_as_loan
    generic = prestamo(
      "alias" => "Crédito personal",
      "descripcion" => "Préstamo personal",
      "indPrestamoHipotecario" => "N"
    )
    payload = normalizer.call({ "prestamos" => [generic] })
    assert_equal "loan", payload.liabilities.first.type
  end

  # --- transactions ------------------------------------------------------

  def test_transaction_canonical_fields
    raw = { "cuentas" => [cuenta], "cuenta_movements" => { "C-001" => [movement] } }
    txn = normalizer.call(raw).transactions.first

    assert_match(/\Atxn_[0-9a-f]{16}\z/, txn.id)
    assert_equal "M-1",                 txn.source_id
    assert_equal Date.new(2024, 3, 15), txn.date
    assert_equal BigDecimal("-45.20"),  txn.amount
    assert_equal "EUR",                 txn.currency
    assert_equal "COFFEE SHOP",         txn.description
  end

  def test_transaction_fallback_id_is_sha1_hex
    mv = movement("numMovimiento" => nil, "nummov" => nil, "idMovimiento" => nil,
                  "referenciaUnica" => nil, "id" => nil)
    raw = { "cuentas" => [cuenta], "cuenta_movements" => { "C-001" => [mv] } }
    txn = normalizer.call(raw).transactions.first

    refute_nil txn
    assert_match(/\Ah:[0-9a-f]{16}\z/, txn.source_id)
  end

  def test_skips_zero_amount_movements
    mv = movement("importe" => { "cantidad" => 0, "divisa" => "EUR" })
    raw = { "cuentas" => [cuenta], "cuenta_movements" => { "C-001" => [mv] } }
    assert_empty normalizer.call(raw).transactions
  end

  # --- determinism / wire -----------------------------------------------

  # D1: two passes over the same raw payload must produce byte-identical
  # canonical-id arrays for every entity kind. See
  # simplefreen/reports/freentonic-id-stability-spec.md §Audit evidence —
  # ING was the only provider audited there; this test pins the same
  # property for Unicaja in CI against all three product kinds (cuenta,
  # tarjeta, prestamo) plus the movement-id field-name fallback path
  # (commit c226425), so any future non-idempotent change is caught
  # before it ships.
  def test_ids_are_deterministic_across_multi_record_payload
    raw = {
      "cuentas"   => [
        cuenta("ppp" => "C-001"),
        cuenta("ppp" => "C-002", "iban" => "ES1121030001234567897251",
               "alias" => "Cuenta nómina")
      ],
      "tarjetas"  => [tarjeta("ppp" => "T-001",
                              "numtarjeta" => "4174804472951018")],
      "prestamos" => [prestamo("ppp" => "P-001")],
      "cuenta_movements"  => {
        "C-001" => [
          movement("numMovimiento" => "M-1"),
          # Exercise the nummov/numMovimiento dedupe path from c226425.
          movement("nummov" => "M-2", "concepto" => "TRAIN",
                   "importe" => { "cantidad" => -3.50, "divisa" => "EUR" })
        ],
        "C-002" => [movement("numMovimiento" => "M-3", "concepto" => "SALARY",
                             "importe" => { "cantidad" => 1500.0, "divisa" => "EUR" })]
      },
      "tarjeta_movements" => {
        "T-001" => [movement("numMovimiento" => "M-T1", "concepto" => "AMAZON",
                             "importe" => { "cantidad" => -8.0, "divisa" => "EUR" })]
      }
    }
    a = normalizer.call(JSON.parse(JSON.generate(raw)))
    b = normalizer.call(JSON.parse(JSON.generate(raw)))

    refute_empty a.accounts
    refute_empty a.transactions
    refute_empty a.liabilities
    assert_equal a.accounts.map(&:id),     b.accounts.map(&:id)
    assert_equal a.transactions.map(&:id), b.transactions.map(&:id)
    assert_equal a.liabilities.map(&:id),  b.liabilities.map(&:id)
  end

  def test_account_id_collides_with_fintonic_for_same_physical_account
    raw = { "cuentas" => [cuenta("iban" => "ES5921030001234567891272")] }
    acct = normalizer.call(raw).accounts.first
    fintonic_id = Freentonic::Canonical.account_id(
      institution: "fintonic", portable_ref: "2103:1272"
    )
    assert_equal fintonic_id, acct.id
    assert_equal "bank:2103:1272", acct.portable_id
  end

  def test_account_without_iban_falls_back_to_legacy_derivation
    raw = { "cuentas" => [cuenta("iban" => nil, "IBAN" => nil)] }
    acct = normalizer.call(raw).accounts.first
    legacy = Freentonic::Canonical.account_id(
      institution: "unicaja", source_id: "cuenta:C-001"
    )
    assert_equal legacy, acct.id
    assert_nil acct.portable_id
  end

  def test_credit_card_id_collides_with_fintonic_creditcard_via_pan_last4
    raw = { "tarjetas" => [tarjeta("numtarjeta" => "5540 29** **** 8619")] }
    acct = normalizer.call(raw).accounts.first
    fintonic_id = Freentonic::Canonical.account_id(
      institution: "fintonic", portable_ref: "2103:8619"
    )
    assert_equal fintonic_id, acct.id
    assert_equal "card:2103:8619", acct.portable_id
  end

  def test_credit_card_without_pan_falls_back_to_legacy_derivation
    raw = { "tarjetas" => [tarjeta("numtarjeta" => nil)] }
    acct = normalizer.call(raw).accounts.first
    legacy = Freentonic::Canonical.account_id(
      institution: "unicaja", source_id: "tarjeta:T-001"
    )
    assert_equal legacy, acct.id
    assert_nil acct.portable_id
  end

  def test_same_day_duplicate_movements_get_distinct_ids
    movs = [
      movement("numMovimiento" => "M-A", "concepto" => "KEPLER"),
      movement("numMovimiento" => "M-B", "concepto" => "KEPLER")
    ]
    raw = { "cuentas" => [cuenta], "cuenta_movements" => { "C-001" => movs } }
    txs = normalizer.call(raw).transactions
    assert_equal 2, txs.size
    refute_equal txs[0].id, txs[1].id
  end

  def test_wire_format_no_cents_keys
    raw = {
      "cuentas"   => [cuenta],
      "tarjetas"  => [tarjeta],
      "prestamos" => [prestamo],
      "cuenta_movements" => { "C-001" => [movement] }
    }
    wire = normalizer.call(raw).to_h

    assert_equal "0.1", wire["schema_version"]
    # BigDecimal.to_s("F") strips trailing zeros, so -45.20 wires as "-45.2".
    assert_equal "-45.2", wire["transactions"].first["amount"]
    refute_includes wire.to_s, "_cents"
  end
end

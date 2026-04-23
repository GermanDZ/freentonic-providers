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

  def test_cuenta_legacy_metadata
    meta = normalizer.call({ "cuentas" => [cuenta] }).accounts.first.metadata
    assert_equal "unicaja_live:cuenta:C-001", meta["legacy_external_id"]
    assert_equal ["unicaja_live:cuenta:C-001"], meta["legacy_uids"]
    assert_equal "unicaja", meta["legacy_bank_key"]
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

  def test_tarjeta_legacy_metadata_uses_cc_bank_key
    meta = normalizer.call({ "tarjetas" => [tarjeta] }).accounts.first.metadata
    assert_equal "unicaja_live:tarjeta:T-001", meta["legacy_external_id"]
    assert_equal "unicaja_cc", meta["legacy_bank_key"]
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

  def test_prestamo_legacy_metadata
    meta = normalizer.call({ "prestamos" => [prestamo] }).accounts.first.metadata
    assert_equal "unicaja_live:prestamo:P-001", meta["legacy_external_id"]
    assert_equal "unicaja_loan", meta["legacy_bank_key"]
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
    assert_equal "unicaja_live:C-001:M-1", txn.metadata["legacy_dedup_key"]
  end

  def test_transaction_fallback_id_is_sha1_hex
    mv = movement("numMovimiento" => nil, "nummov" => nil, "idMovimiento" => nil,
                  "referenciaUnica" => nil, "id" => nil)
    raw = { "cuentas" => [cuenta], "cuenta_movements" => { "C-001" => [mv] } }
    txn = normalizer.call(raw).transactions.first

    refute_nil txn
    assert_match(/\Ah:[0-9a-f]{16}\z/, txn.source_id)
    assert_match(/\Aunicaja_live:C-001:h:[0-9a-f]{16}\z/, txn.metadata["legacy_dedup_key"])
  end

  def test_skips_zero_amount_movements
    mv = movement("importe" => { "cantidad" => 0, "divisa" => "EUR" })
    raw = { "cuentas" => [cuenta], "cuenta_movements" => { "C-001" => [mv] } }
    assert_empty normalizer.call(raw).transactions
  end

  # --- determinism / wire -----------------------------------------------

  def test_ids_are_deterministic
    raw = { "cuentas" => [cuenta], "cuenta_movements" => { "C-001" => [movement] } }
    a = normalizer.call(raw)
    b = normalizer.call(raw)
    assert_equal a.accounts.first.id,     b.accounts.first.id
    assert_equal a.transactions.first.id, b.transactions.first.id
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

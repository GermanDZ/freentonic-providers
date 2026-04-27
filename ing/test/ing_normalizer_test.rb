# frozen_string_literal: true

require "minitest/autorun"
require "bigdecimal"
require "freentonic"
require_relative "../extractor"
require_relative "../normalizer"

class IngNormalizerTest < Minitest::Test
  def normalizer
    Freentonic::Providers::Ing::Normalizer.new
  end

  def asset_product(overrides = {})
    {
      "uuid"          => "prod-1",
      "type"          => 20, # Cuenta NARANJA
      "alias"         => "My checking",
      "productNumber" => "ES0012345",
      "iban"          => "ES00 1234 5678 9012 3456 7890",
      "currency"      => "EUR",
      "balance"       => 1234.56,
      "movements"     => []
    }.merge(overrides)
  end

  def asset_movement(overrides = {})
    {
      "uuid"          => "mv-1",
      "amount"        => -12.34,
      "effectiveDate" => "15/03/2024",
      "description"   => "COFFEE SHOP",
      "currency"      => "EUR"
    }.merge(overrides)
  end

  # --- envelope + shape --------------------------------------------------

  def test_returns_canonical_payload
    payload = normalizer.call([asset_product("movements" => [asset_movement])])

    assert_kind_of Freentonic::Canonical::CanonicalPayload, payload
    assert_equal "0.1", payload.schema_version
    assert_equal "ing/0.2", payload.meta["scraper_version"]
    assert_equal 1, payload.accounts.size
    assert_equal 1, payload.transactions.size
    assert_equal 0, payload.liabilities.size
  end

  def test_asset_account_canonical_fields
    payload = normalizer.call([asset_product])
    acct = payload.accounts.first

    assert_match(/\Aacc_[0-9a-f]{16}\z/, acct.id)
    assert_equal "ing",      acct.institution
    assert_equal "checking", acct.type
    assert_equal "prod-1",   acct.source_id
    assert_equal "My checking", acct.name
    assert_equal "ES0012345678901234567890", acct.iban
    assert_equal "EUR",      acct.currency
    assert_equal BigDecimal("1234.56"), acct.balance.current
    assert_nil               acct.balance.timestamp
  end

  def test_asset_account_provider_metadata_is_preserved
    payload = normalizer.call([asset_product])
    acct = payload.accounts.first

    assert_equal 20, acct.metadata["ing_product_type"]
    assert_equal "ing_live:product_balance", acct.metadata["balance_source"]
  end

  # --- liability (credit card) ------------------------------------------

  def credit_card_product(overrides = {})
    {
      "uuid"             => "cc-1",
      "type"             => 3,
      "alias"            => "Visa",
      "name"             => "Tarjeta Crédito",
      "productNumber"    => "4174804472951018",
      "currency"         => "EUR",
      "creditLimit"      => 6500.0,
      "availableBalance" => 4317.19,
      "movements"        => []
    }.merge(overrides)
  end

  def test_credit_card_emits_account_plus_liability
    payload = normalizer.call([credit_card_product("uuid" => "cc-1", "alias" => "Visa")])
    assert_equal 1, payload.accounts.size
    assert_equal 1, payload.liabilities.size

    acct = payload.accounts.first
    assert_equal "credit_card", acct.type
    assert_equal "ing",         acct.institution

    liab = payload.liabilities.first
    assert_match(/\Aliab_[0-9a-f]{16}\z/, liab.id)
    assert_equal acct.id,       liab.account_id
    assert_equal "credit_card", liab.type
    assert_equal "EUR",         liab.currency
    assert_equal "cc-1",        liab.source_id
  end

  def test_credit_card_balance_is_outstanding_negated
    # creditLimit 6500 - availableBalance 4317.19 = 2182.81 outstanding,
    # stored as a negative number (it's a liability — money owed).
    payload = normalizer.call([credit_card_product])
    acct = payload.accounts.first
    assert_equal BigDecimal("-2182.81"), acct.balance.current
    assert_equal "ing_live:credit_limit_minus_available", acct.metadata["balance_source"]
  end

  def test_credit_card_with_no_outstanding_is_zero
    payload = normalizer.call([credit_card_product("creditLimit" => 1485.0,
                                                   "availableBalance" => 1485.0)])
    acct = payload.accounts.first
    assert_equal BigDecimal("0"), acct.balance.current
    assert_equal "ing_live:credit_limit_minus_available", acct.metadata["balance_source"]
  end

  def test_credit_card_without_limit_or_available_has_nil_balance
    # Defensive: if ING ever changes the shape and stops emitting either
    # field, surface that as missing (the canonical reshape will then
    # report it in errors[]) rather than silently emitting 0.
    payload = normalizer.call([credit_card_product("creditLimit" => nil,
                                                   "availableBalance" => nil)])
    acct = payload.accounts.first
    assert_nil acct.balance.current
    assert_nil acct.metadata["balance_source"]
  end

  # --- transactions ------------------------------------------------------

  def test_transaction_canonical_fields
    payload = normalizer.call([asset_product("movements" => [asset_movement])])
    txn = payload.transactions.first

    assert_match(/\Atxn_[0-9a-f]{16}\z/, txn.id)
    assert_equal payload.accounts.first.id, txn.account_id
    assert_equal "mv-1",               txn.source_id
    assert_equal Date.new(2024, 3, 15),  txn.date
    assert_equal BigDecimal("-12.34"),   txn.amount
    assert_equal "EUR",                txn.currency
    assert_equal "COFFEE SHOP",        txn.description
    assert_equal "COFFEE SHOP",        txn.raw_description
    assert_equal "posted",             txn.status
  end

  def test_transaction_pending_status_maps_to_pending
    mv = asset_movement(
      "status" => { "description" => "Pendiente de liquidar" }
    )
    payload = normalizer.call([asset_product("movements" => [mv])])
    assert_equal "pending", payload.transactions.first.status
  end

  def test_transaction_carries_raw_provider_metadata
    mv = asset_movement
    payload = normalizer.call([asset_product("movements" => [mv])])
    txn = payload.transactions.first

    assert_equal "mv-1", txn.metadata["ing"]["uuid"]
  end

  def test_value_date_populated_from_clearing_date
    mv = asset_movement("clearingDate" => "20/03/2024")
    payload = normalizer.call([asset_product("movements" => [mv])])
    assert_equal Date.new(2024, 3, 20), payload.transactions.first.value_date
  end

  def test_ids_are_deterministic
    product = asset_product("movements" => [asset_movement])
    a = normalizer.call([product])
    b = normalizer.call([product])

    assert_equal a.accounts.first.id,    b.accounts.first.id
    assert_equal a.transactions.first.id, b.transactions.first.id
  end

  # --- filtering edge cases ---------------------------------------------

  def test_skips_debit_card_products
    payload = normalizer.call([{ "uuid" => "dc-1", "type" => 1, "movements" => [] }])
    assert_empty payload.accounts
    assert_empty payload.transactions
  end

  def test_skips_zero_amount_movement
    mv = asset_movement("amount" => 0)
    payload = normalizer.call([asset_product("movements" => [mv])])
    assert_empty payload.transactions
  end

  def test_skips_movement_without_uuid
    mv = asset_movement("uuid" => nil)
    payload = normalizer.call([asset_product("movements" => [mv])])
    assert_empty payload.transactions
  end

  def test_wire_format_money_is_string_no_cents_keys
    payload = normalizer.call([asset_product("movements" => [asset_movement])])
    wire = payload.to_h

    assert_equal "0.1", wire["schema_version"]
    assert_equal "1234.56", wire["accounts"].first["balance"]["current"]
    assert_equal "-12.34",  wire["transactions"].first["amount"]
    # No legacy "_cents" keys anywhere in wire output.
    serialized = wire.to_s
    refute_includes serialized, "_cents"
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "bigdecimal"
require "freentonic"
require_relative "../normalizer"

class FintonicNormalizerTest < Minitest::Test
  def normalizer
    Freentonic::Providers::Fintonic::Normalizer.new
  end

  def make_tx(overrides = {})
    {
      "id"             => "tx-1",
      "bankId"         => "1465",
      "productId"      => "9001",
      "type"           => "ACCOUNT",
      "_bank_name"     => "ING",
      "quantity"       => -2314,
      "currency"       => "EURO",
      "userDate"       => "2024-06-15",
      "valueDate"      => "2024-06-14",
      "operationDate"  => "2024-06-13",
      "reference"      => "ref-001",
      "description"    => "MERCADONA",
      "cleanNote"      => nil,
      "userDescription" => nil,
      "primaryDisplay" => "Mercadona S.A.",
      "categorization" => { "weightedCategories" => { "cat-42" => 0.95 } }
    }.merge(overrides)
  end

  def make_raw(transactions: [make_tx], category_tree: {})
    { "categoryTree" => category_tree, "transactions" => transactions }
  end

  # --- envelope + shape --------------------------------------------------

  def test_returns_canonical_payload
    payload = normalizer.call(make_raw)

    assert_kind_of Freentonic::Canonical::CanonicalPayload, payload
    assert_equal "fintonic/0.2", payload.meta["scraper_version"]
    assert_equal 1, payload.accounts.size
    assert_equal 1, payload.transactions.size
    assert_equal 0, payload.liabilities.size
  end

  def test_account_canonical_fields
    payload = normalizer.call(make_raw)
    acct = payload.accounts.first

    assert_match(/\Aacc_[0-9a-f]{16}\z/, acct.id)
    assert_equal "fintonic",    acct.institution
    assert_equal "checking",    acct.type
    assert_equal "1465:9001",   acct.source_id
    assert_equal "ING ACCOUNT #9001", acct.name
    assert_equal "EUR",         acct.currency
    assert_nil                  acct.iban
    assert_nil                  acct.balance
    # Own metadata preserved.
    assert_equal "1465", acct.metadata["fintonic_bank_id"]
  end

  def test_account_legacy_compat_metadata
    payload = normalizer.call(make_raw)
    meta = payload.accounts.first.metadata

    assert_equal "fintonic:1465:9001", meta["legacy_external_id"]
    assert_equal ["fintonic-1465-9001-ACCOUNT"], meta["legacy_uids"]
    assert_equal "fintonic_1465", meta["legacy_bank_key"]
  end

  # --- credit cards ------------------------------------------------------

  def test_credit_card_underscore_emits_account_plus_liability
    payload = normalizer.call(make_raw(transactions: [make_tx("type" => "CREDIT_CARD")]))
    acct = payload.accounts.first

    assert_equal "credit_card", acct.type
    assert_equal ["fintonic-1465-9001-CREDIT_CARD"], acct.metadata["legacy_uids"]

    assert_equal 1, payload.liabilities.size
    liab = payload.liabilities.first
    assert_equal acct.id,       liab.account_id
    assert_equal "credit_card", liab.type
    assert_equal "1465:9001",   liab.source_id
  end

  def test_creditcard_no_underscore_is_liability
    payload = normalizer.call(make_raw(transactions: [make_tx("type" => "CREDITCARD")]))

    assert_equal ["fintonic-1465-9001-CREDITCARD"],
                 payload.accounts.first.metadata["legacy_uids"]
    assert_equal 1, payload.liabilities.size
  end

  # --- transactions ------------------------------------------------------

  def test_transaction_canonical_fields
    payload = normalizer.call(make_raw)
    txn = payload.transactions.first

    assert_match(/\Atxn_[0-9a-f]{16}\z/, txn.id)
    assert_equal payload.accounts.first.id, txn.account_id
    assert_equal "tx-1",             txn.source_id
    assert_equal Date.new(2024, 6, 15), txn.date
    assert_equal BigDecimal("-23.14"), txn.amount
    assert_equal "EUR",              txn.currency
    assert_equal "MERCADONA",        txn.raw_description
    assert_equal "MERCADONA",        txn.description
  end

  def test_transaction_legacy_dedup_key
    payload = normalizer.call(make_raw)
    assert_equal "fintonic:tx-1", payload.transactions.first.metadata["legacy_dedup_key"]
  end

  def test_positive_amount_is_income
    payload = normalizer.call(make_raw(transactions: [make_tx("quantity" => 50_000)]))
    assert_equal BigDecimal("500.00"), payload.transactions.first.amount
  end

  def test_skips_zero_amount
    payload = normalizer.call(make_raw(transactions: [make_tx("quantity" => 0)]))
    assert_empty payload.transactions
  end

  def test_skips_nil_amount
    payload = normalizer.call(make_raw(transactions: [make_tx("quantity" => nil)]))
    assert_empty payload.transactions
  end

  def test_falls_back_to_value_date
    payload = normalizer.call(make_raw(transactions: [make_tx("userDate" => nil, "valueDate" => "2024-07-01")]))
    assert_equal Date.new(2024, 7, 1), payload.transactions.first.date
  end

  def test_skips_when_no_date
    payload = normalizer.call(make_raw(transactions: [make_tx("userDate" => nil, "valueDate" => nil)]))
    assert_empty payload.transactions
  end

  def test_description_with_user_description
    payload = normalizer.call(
      make_raw(transactions: [make_tx("description" => "BIZUM", "userDescription" => "Cena amigos")])
    )
    txn = payload.transactions.first
    assert_equal "BIZUM | Cena amigos", txn.description
    assert_equal "BIZUM",               txn.raw_description
  end

  def test_category_resolved_from_tree
    tree = {
      "cat-1"  => { "name" => "Gastos", "ancestors" => [] },
      "cat-42" => { "name" => "Supermercado", "ancestors" => ["cat-1"] }
    }
    payload = normalizer.call(make_raw(category_tree: tree))
    txn = payload.transactions.first

    assert_equal "Gastos/Supermercado", txn.category
    # And still preserved under provider metadata for anyone needing the raw path.
    assert_equal "Gastos/Supermercado", txn.metadata["fintonic"]["category_path"]
    assert_equal "cat-42",              txn.metadata["fintonic"]["category_id"]
  end

  def test_groups_by_product
    txs = [
      make_tx("productId" => "9001", "type" => "ACCOUNT"),
      make_tx("id" => "tx-2", "productId" => "9002", "type" => "CREDITCARD")
    ]
    payload = normalizer.call(make_raw(transactions: txs))

    assert_equal 2, payload.accounts.size
    types = payload.accounts.map(&:type).sort
    assert_equal %w[checking credit_card], types
    assert_equal 1, payload.liabilities.size
  end

  def test_euro_currency_normalized
    payload = normalizer.call(make_raw(transactions: [make_tx("currency" => "EURO")]))
    assert_equal "EUR", payload.transactions.first.currency
  end

  def test_preserves_raw_fintonic_fields_in_metadata
    payload = normalizer.call(make_raw)
    fintonic = payload.transactions.first.metadata["fintonic"]

    assert_equal "tx-1",       fintonic["id"]
    assert_equal "ref-001",    fintonic["reference"]
    assert_equal "2024-06-13", fintonic["operationDate"]
  end

  def test_merchant_from_primary_display_when_no_explicit_name
    payload = normalizer.call(make_raw)
    merchant = payload.transactions.first.merchant

    refute_nil merchant
    assert_equal "Mercadona S.A.", merchant.name
    assert_equal false, merchant.normalized
  end

  def test_merchant_explicit_name_marks_as_normalized
    payload = normalizer.call(make_raw(transactions: [make_tx("merchant_name" => "Mercadona")]))
    merchant = payload.transactions.first.merchant

    assert_equal "Mercadona", merchant.name
    assert_equal true, merchant.normalized
  end

  def test_ids_are_deterministic
    a = normalizer.call(make_raw)
    b = normalizer.call(make_raw)
    assert_equal a.accounts.first.id,    b.accounts.first.id
    assert_equal a.transactions.first.id, b.transactions.first.id
  end

  def test_wire_format_money_string_no_cents
    wire = normalizer.call(make_raw).to_h
    assert_equal "-23.14", wire["transactions"].first["amount"]
    refute_includes wire.to_s, "_cents"
  end
end

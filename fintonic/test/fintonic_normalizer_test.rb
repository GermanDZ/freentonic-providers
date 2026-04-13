# frozen_string_literal: true

require "minitest/autorun"
require "freentonic"
require_relative "../normalizer"

class FintonicNormalizerTest < Minitest::Test
  def normalizer
    Freentonic::Providers::Fintonic::Normalizer.new
  end

  def make_tx(overrides = {})
    {
      "id"        => "tx-1",
      "bankId"    => "1465",
      "productId" => "9001",
      "type"      => "ACCOUNT",
      "_bank_name" => "ING",
      "quantity"  => -2314,
      "currency"  => "EURO",
      "userDate"  => "2024-06-15",
      "valueDate" => "2024-06-14",
      "operationDate" => "2024-06-13",
      "reference" => "ref-001",
      "description" => "MERCADONA",
      "cleanNote"    => nil,
      "userDescription"  => nil,
      "primaryDisplay"   => "Mercadona S.A.",
      "categorization" => {
        "weightedCategories" => { "cat-42" => 0.95 }
      }
    }.merge(overrides)
  end

  def make_raw(transactions: [make_tx], category_tree: {})
    { "categoryTree" => category_tree, "transactions" => transactions }
  end

  def test_normalizes_account_with_movement
    raw = make_raw
    payload = normalizer.call(raw)

    assert_equal "fintonic_push", payload["source_tag"]
    assert_equal 1, payload["accounts"].size

    acct = payload["accounts"].first
    assert_equal "fintonic:1465:9001", acct["external_id"]
    assert_equal ["fintonic-1465-9001-ACCOUNT"], acct["legacy_uids"]
    assert_equal "asset", acct["kind"]
    assert_equal "fintonic_1465", acct["bank_key"]
    assert_equal "EUR", acct["currency"]

    mv = acct["movements"].first
    assert_equal "fintonic:tx-1", mv["dedup_key"]
    assert_equal "2024-06-15", mv["date"]
    assert_equal(-2314, mv["amount_cents"])
    assert_equal "EUR", mv["currency"]
    assert_equal "MERCADONA", mv["description"]
  end

  def test_credit_card_underscore_is_liability
    raw = make_raw(transactions: [make_tx("type" => "CREDIT_CARD")])
    payload = normalizer.call(raw)

    acct = payload["accounts"].first
    assert_equal "liability", acct["kind"]
    assert_equal ["fintonic-1465-9001-CREDIT_CARD"], acct["legacy_uids"]
  end

  def test_creditcard_no_underscore_is_liability
    raw = make_raw(transactions: [make_tx("type" => "CREDITCARD")])
    payload = normalizer.call(raw)

    acct = payload["accounts"].first
    assert_equal "liability", acct["kind"]
    assert_equal ["fintonic-1465-9001-CREDITCARD"], acct["legacy_uids"]
  end

  def test_positive_amount_is_income
    raw = make_raw(transactions: [make_tx("quantity" => 50000)])
    payload = normalizer.call(raw)

    mv = payload["accounts"].first["movements"].first
    assert_equal 50000, mv["amount_cents"]
  end

  def test_skips_zero_amount
    raw = make_raw(transactions: [make_tx("quantity" => 0)])
    payload = normalizer.call(raw)

    assert_equal 0, payload["accounts"].first["movements"].size
  end

  def test_skips_nil_amount
    raw = make_raw(transactions: [make_tx("quantity" => nil)])
    payload = normalizer.call(raw)

    assert_equal 0, payload["accounts"].first["movements"].size
  end

  def test_falls_back_to_value_date
    raw = make_raw(transactions: [make_tx("userDate" => nil, "valueDate" => "2024-07-01")])
    payload = normalizer.call(raw)

    mv = payload["accounts"].first["movements"].first
    assert_equal "2024-07-01", mv["date"]
  end

  def test_skips_when_no_date
    raw = make_raw(transactions: [make_tx("userDate" => nil, "valueDate" => nil)])
    payload = normalizer.call(raw)

    assert_equal 0, payload["accounts"].first["movements"].size
  end

  def test_description_with_user_description
    raw = make_raw(transactions: [make_tx("description" => "BIZUM", "userDescription" => "Cena amigos")])
    payload = normalizer.call(raw)

    mv = payload["accounts"].first["movements"].first
    assert_equal "BIZUM | Cena amigos", mv["description"]
  end

  def test_category_resolved_from_tree
    category_tree = {
      "cat-1"  => { "name" => "Gastos", "ancestors" => [] },
      "cat-42" => { "name" => "Supermercado", "ancestors" => ["cat-1"] }
    }
    raw = make_raw(category_tree: category_tree)
    payload = normalizer.call(raw)

    mv = payload["accounts"].first["movements"].first
    assert_equal "Gastos/Supermercado", mv["raw_payload"]["fintonic"]["category_path"]
    assert_equal "cat-42", mv["raw_payload"]["fintonic"]["category_id"]
  end

  def test_groups_by_product
    txs = [
      make_tx("productId" => "9001", "type" => "ACCOUNT"),
      make_tx("id" => "tx-2", "productId" => "9002", "type" => "CREDITCARD")
    ]
    raw = make_raw(transactions: txs)
    payload = normalizer.call(raw)

    assert_equal 2, payload["accounts"].size
    kinds = payload["accounts"].map { |a| a["kind"] }.sort
    assert_equal %w[asset liability], kinds
  end

  def test_euro_currency_normalized
    raw = make_raw(transactions: [make_tx("currency" => "EURO")])
    payload = normalizer.call(raw)

    mv = payload["accounts"].first["movements"].first
    assert_equal "EUR", mv["currency"]
  end

  def test_preserves_raw_fintonic_fields
    raw = make_raw
    payload = normalizer.call(raw)

    fintonic = payload["accounts"].first["movements"].first["raw_payload"]["fintonic"]
    assert_equal "tx-1", fintonic["id"]
    assert_equal "ref-001", fintonic["reference"]
    assert_equal "2024-06-13", fintonic["operationDate"]
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "freentonic"
require_relative "../extractor"
require_relative "../normalizer"

# Smoke tests for the ING normalizer — verifies it turns a realistic
# raw ING product payload into the universal bank-push shape.
class IngNormalizerTest < Minitest::Test
  def test_normalizes_an_asset_product_with_movements
    raw = [
      {
        "uuid"          => "prod-1",
        "type"          => 20, # Cuenta NARANJA
        "alias"         => "My checking",
        "productNumber" => "ES0012345",
        "iban"          => "ES00 1234 5678 9012 3456 7890",
        "currency"      => "EUR",
        "balance"       => 1234.56,
        "movements" => [
          {
            "uuid"          => "mv-1",
            "amount"        => -12.34,
            "effectiveDate" => "15/03/2024",
            "description"   => "Coffee",
            "currency"      => "EUR"
          }
        ]
      }
    ]

    payload = Freentonic::Providers::Ing::Normalizer.new.call(raw)
    assert_equal "ing_push", payload["source_tag"]

    accounts = payload["accounts"]
    assert_equal 1, accounts.size

    acct = accounts.first
    assert_equal "ing_live:prod-1", acct["external_id"]
    assert_equal "asset",          acct["kind"]
    assert_equal "ing",            acct["bank_key"]
    assert_equal 123_456,          acct["balance_cents"]
    assert_equal "ES001234567890123456 7890".gsub(" ", ""), acct["iban"]

    mv = acct["movements"].first
    assert_equal "ing_live:prod-1:mv-1", mv["dedup_key"]
    assert_equal "2024-03-15", mv["date"]
    assert_equal(-1234,        mv["amount_cents"])
    assert_equal "Coffee",     mv["description"]
  end

  def test_skips_debit_card_products
    raw = [{ "uuid" => "dc-1", "type" => 1, "movements" => [] }]
    payload = Freentonic::Providers::Ing::Normalizer.new.call(raw)
    assert_empty payload["accounts"]
  end
end

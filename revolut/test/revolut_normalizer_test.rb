# frozen_string_literal: true

require "minitest/autorun"
require "bigdecimal"
require "freentonic"
require_relative "../normalizer"

class RevolutNormalizerTest < Minitest::Test
  def normalizer
    Freentonic::Providers::Revolut::Normalizer.new
  end

  def pocket_raw
    {
      "wallet"  => { "id" => "w1" },
      "pockets" => [
        {
          "id"       => "pocket-eur-1",
          "name"     => "Main EUR",
          "currency" => "EUR",
          "balance"  => 123_456,
          "type"     => "CURRENT"
        }
      ],
      "bank_details" => [
        { "currency" => "EUR", "details" => { "accounts" => [{ "iban" => "LT00 1234 5678 9012 3456" }] } }
      ],
      "cards"  => [],
      "vaults" => [],
      "pocket_transactions" => {
        "pocket-eur-1" => [
          {
            "id"          => "tx-1",
            "startedDate" => 1_710_504_000_000,
            "amount"      => -1234,
            "currency"    => "EUR",
            "description" => "Coffee Shop",
            "type"        => "CARD_PAYMENT"
          },
          {
            "id"          => "tx-2",
            "startedDate" => 1_710_417_600_000,
            "amount"      => 50_000,
            "currency"    => "EUR",
            "description" => "Bank Transfer",
            "type"        => "TRANSFER"
          }
        ]
      }
    }
  end

  # --- envelope + pocket shape ------------------------------------------

  def test_returns_canonical_payload
    payload = normalizer.call(pocket_raw)

    assert_kind_of Freentonic::Canonical::CanonicalPayload, payload
    assert_equal "revolut/0.2", payload.meta["scraper_version"]
    assert_equal 1, payload.accounts.size
    assert_equal 2, payload.transactions.size
  end

  def test_pocket_account_canonical_fields
    payload = normalizer.call(pocket_raw)
    acct = payload.accounts.first

    assert_match(/\Aacc_[0-9a-f]{16}\z/, acct.id)
    assert_equal "revolut",            acct.institution
    assert_equal "checking",           acct.type
    assert_equal "pocket:pocket-eur-1", acct.source_id
    assert_equal "LT00 1234 5678 9012 3456", acct.iban
    assert_equal BigDecimal("1234.56"), acct.balance.current
  end

  def test_pocket_legacy_compat_metadata
    meta = normalizer.call(pocket_raw).accounts.first.metadata

    assert_equal "revolut_live:pocket:pocket-eur-1", meta["legacy_external_id"]
    assert_equal ["revolut_live:pocket:pocket-eur-1"], meta["legacy_uids"]
    assert_equal "revolut", meta["legacy_bank_key"]
  end

  def test_pocket_transactions
    payload = normalizer.call(pocket_raw)
    txn = payload.transactions.find { |t| t.source_id == "tx-1" }

    assert_equal payload.accounts.first.id, txn.account_id
    assert_equal BigDecimal("-12.34"),     txn.amount
    assert_equal Date.new(2024, 3, 15),     txn.date
    assert_equal "Coffee Shop",            txn.description
    assert_equal "Coffee Shop",            txn.raw_description
    assert_equal "revolut_live:pocket-eur-1:tx-1", txn.metadata["legacy_dedup_key"]
  end

  # --- vaults ------------------------------------------------------------

  def vault_raw
    {
      "wallet" => {},
      "pockets" => [],
      "bank_details" => [],
      "cards" => [],
      "vaults" => [
        {
          "id"       => "vault-1",
          "name"     => "Holiday Fund",
          "currency" => "EUR",
          "balance"  => { "amount" => 350.00, "currency" => "EUR" },
          "goal"     => 1000.00
        }
      ],
      "pocket_transactions" => {}
    }
  end

  def test_vault_canonical_fields
    payload = normalizer.call(vault_raw)
    assert_equal 1, payload.accounts.size
    assert_empty payload.transactions

    vault = payload.accounts.first
    assert_equal "savings",              vault.type
    assert_equal "vault:vault-1",        vault.source_id
    assert_equal BigDecimal("350.00"),   vault.balance.current
  end

  def test_vault_legacy_compat_metadata_uses_vault_bank_key
    meta = normalizer.call(vault_raw).accounts.first.metadata

    assert_equal "revolut_live:vault:vault-1", meta["legacy_external_id"]
    assert_equal ["revolut_live:vault:vault-1"], meta["legacy_uids"]
    assert_equal "revolut_vault", meta["legacy_bank_key"]
  end

  # --- edge cases --------------------------------------------------------

  def test_skips_transactions_with_nil_or_zero_amount
    raw = {
      "wallet"  => {},
      "pockets" => [{ "id" => "p1", "currency" => "EUR", "balance" => 10_000 }],
      "bank_details" => [],
      "cards" => [],
      "vaults" => [],
      "pocket_transactions" => {
        "p1" => [
          { "id" => "tx-ok", "startedDate" => 1_710_504_000_000, "amount" => -500, "currency" => "EUR", "description" => "Valid" },
          { "id" => "tx-nil", "startedDate" => 1_710_504_000_000, "amount" => nil, "description" => "No amount" },
          { "id" => "tx-zero", "startedDate" => 1_710_504_000_000, "amount" => 0, "description" => "Zero" }
        ]
      }
    }

    payload = normalizer.call(raw)
    assert_equal 1, payload.transactions.size
    assert_equal "tx-ok", payload.transactions.first.source_id
  end

  def test_parses_iso_date_string
    raw = {
      "wallet"  => {},
      "pockets" => [{ "id" => "p1", "currency" => "EUR", "balance" => 0 }],
      "bank_details" => [],
      "cards" => [],
      "vaults" => [],
      "pocket_transactions" => {
        "p1" => [
          { "id" => "tx-iso", "startedDate" => "2024-03-15T10:00:00.000Z", "amount" => -100, "currency" => "EUR", "description" => "Test" }
        ]
      }
    }
    payload = normalizer.call(raw)
    assert_equal Date.new(2024, 3, 15), payload.transactions.first.date
  end

  def test_merchant_populated_when_present
    raw = pocket_raw
    raw["pocket_transactions"]["pocket-eur-1"][0]["merchant"] = { "name" => "STARBUCKS" }
    payload = normalizer.call(raw)
    merchant = payload.transactions.find { |t| t.source_id == "tx-1" }.merchant

    refute_nil merchant
    assert_equal "STARBUCKS", merchant.name
    assert_equal true, merchant.normalized
  end

  def test_ids_are_deterministic
    a = normalizer.call(pocket_raw)
    b = normalizer.call(pocket_raw)
    assert_equal a.accounts.first.id,    b.accounts.first.id
    assert_equal a.transactions.first.id, b.transactions.first.id
  end

  def test_wire_format_money_string_no_cents
    wire = normalizer.call(pocket_raw).to_h
    assert_equal "-12.34", wire["transactions"].first["amount"]
    refute_includes wire.to_s, "_cents"
  end
end

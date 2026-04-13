require "minitest/autorun"
require "freentonic"
require_relative "../normalizer"

class RevolutNormalizerTest < Minitest::Test
  def normalizer
    Freentonic::Providers::Revolut::Normalizer.new
  end

  def test_normalizes_pocket_with_transactions
    raw = {
      "wallet"  => { "id" => "w1" },
      "pockets" => [
        {
          "id"       => "pocket-eur-1",
          "name"     => "Main EUR",
          "currency" => "EUR",
          "balance"  => 123456,
          "type"     => "CURRENT"
        }
      ],
      "bank_details"        => [
        { "currency" => "EUR", "details" => { "accounts" => [{ "iban" => "LT00 1234 5678 9012 3456" }] } }
      ],
      "cards"               => [],
      "vaults"              => [],
      "pocket_transactions" => {
        "pocket-eur-1" => [
          {
            "id"          => "tx-1",
            "startedDate" => 1710504000000,
            "amount"      => -1234,
            "currency"    => "EUR",
            "description" => "Coffee Shop",
            "type"        => "CARD_PAYMENT"
          },
          {
            "id"          => "tx-2",
            "startedDate" => 1710417600000,
            "amount"      => 50000,
            "currency"    => "EUR",
            "description" => "Bank Transfer",
            "type"        => "TRANSFER"
          }
        ]
      }
    }

    payload = normalizer.call(raw)

    assert_equal "revolut_push", payload["source_tag"]
    assert_equal 1, payload["accounts"].size

    acct = payload["accounts"].first
    assert_equal "revolut_live:pocket:pocket-eur-1", acct["external_id"]
    assert_equal "asset", acct["kind"]
    assert_equal "revolut", acct["bank_key"]
    assert_equal "EUR", acct["currency"]
    assert_equal "LT00 1234 5678 9012 3456", acct["iban"]
    assert_equal 123_456, acct["balance_cents"]
    assert_equal 2, acct["movements"].size

    mv = acct["movements"].first
    assert_equal "revolut_live:pocket-eur-1:tx-1", mv["dedup_key"]
    assert_equal(-1234, mv["amount_cents"])
    assert_equal "2024-03-15", mv["date"]
    assert_equal "Coffee Shop", mv["description"]
  end

  def test_normalizes_vault
    raw = {
      "wallet"              => {},
      "pockets"             => [],
      "bank_details"        => [],
      "cards"               => [],
      "vaults"              => [
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

    payload = normalizer.call(raw)
    assert_equal 1, payload["accounts"].size

    vault_acct = payload["accounts"].first
    assert_equal "revolut_live:vault:vault-1", vault_acct["external_id"]
    assert_equal "asset", vault_acct["kind"]
    assert_equal "revolut_vault", vault_acct["bank_key"]
    assert_equal "Holiday Fund", vault_acct["name"]
    assert_equal 35_000, vault_acct["balance_cents"]
    assert_equal [], vault_acct["movements"]
  end

  def test_skips_transactions_with_nil_amount
    raw = {
      "wallet"  => {},
      "pockets" => [{ "id" => "p1", "currency" => "EUR", "balance" => 10000 }],
      "bank_details"        => [],
      "cards"               => [],
      "vaults"              => [],
      "pocket_transactions" => {
        "p1" => [
          { "id" => "tx-ok", "startedDate" => 1710504000000, "amount" => -500, "currency" => "EUR", "description" => "Valid" },
          { "id" => "tx-nil", "startedDate" => 1710504000000, "amount" => nil, "description" => "No amount" },
          { "id" => "tx-zero", "startedDate" => 1710504000000, "amount" => 0, "description" => "Zero" }
        ]
      }
    }

    payload = normalizer.call(raw)
    movements = payload["accounts"].first["movements"]
    assert_equal 1, movements.size
    assert_equal "revolut_live:p1:tx-ok", movements.first["dedup_key"]
  end

  def test_parses_iso_date_string
    raw = {
      "wallet"  => {},
      "pockets" => [{ "id" => "p1", "currency" => "EUR", "balance" => 0 }],
      "bank_details"        => [],
      "cards"               => [],
      "vaults"              => [],
      "pocket_transactions" => {
        "p1" => [
          { "id" => "tx-iso", "startedDate" => "2024-03-15T10:00:00.000Z", "amount" => -100, "currency" => "EUR", "description" => "Test" }
        ]
      }
    }

    payload = normalizer.call(raw)
    mv = payload["accounts"].first["movements"].first
    assert_equal "2024-03-15", mv["date"]
  end
end

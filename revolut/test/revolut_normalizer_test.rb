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
    # Revolut pockets share the parent wallet's IBAN, so we don't
    # surface it on Account#iban (would collide canonical ids across
    # pockets). It's preserved in metadata for traceability.
    assert_nil acct.iban
    assert_equal "LT00 1234 5678 9012 3456", acct.metadata["revolut_parent_iban"]
    assert_equal BigDecimal("1234.56"), acct.balance.current
  end

  def test_multiple_pockets_with_same_currency_get_distinct_canonical_ids
    # Real-world Revolut: a user has a main "Revolut EUR" pocket plus
    # named sub-pockets ("Experimento 1", money market funds, …). All
    # share the same EUR IBAN but each has its own pocket id and
    # balance. Canonical ids must be distinct so SimpleFIN consumers
    # don't dedupe them and clobber the main pocket's balance.
    raw = {
      "wallet"  => {},
      "pockets" => [
        { "id" => "p-main",  "currency" => "EUR", "balance" => 22_437,
          "name" => "Revolut EUR" },
        { "id" => "p-saved", "currency" => "EUR", "balance" => 0,
          "name" => "Experimento 1" },
        { "id" => "p-mmf",   "currency" => "EUR", "balance" => 0,
          "name" => "MMF:aff2f52c-1f4c-40f2-a601-07fe17ec0bd2" }
      ],
      "bank_details" => [
        { "currency" => "EUR", "details" => { "accounts" => [{ "iban" => "LT00 1234 5678 9012 3456" }] } }
      ],
      "vaults" => []
    }
    payload = normalizer.call(raw)

    ids = payload.accounts.map(&:id)
    assert_equal 3, ids.size
    assert_equal ids.size, ids.uniq.size, "every pocket must get a distinct canonical id"

    main = payload.accounts.find { |a| a.source_id == "pocket:p-main" }
    assert_equal BigDecimal("224.37"), main.balance.current
  end

  def test_pocket_transactions
    payload = normalizer.call(pocket_raw)
    txn = payload.transactions.find { |t| t.source_id == "tx-1" }

    assert_equal payload.accounts.first.id, txn.account_id
    assert_equal BigDecimal("-12.34"),     txn.amount
    assert_equal Date.new(2024, 3, 15),     txn.date
    assert_equal "Coffee Shop",            txn.description
    assert_equal "Coffee Shop",            txn.raw_description
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

  # Regression: Revolut returns internal transfers (TRANSFER, EXCHANGE, …)
  # as a single envelope with multiple legs — every leg carries the
  # same `id` (the transfer id) but a distinct `legId`. A previous
  # version of build_transaction used `tx["id"] || tx["legId"]`, so
  # both legs got the same source_id, collapsed onto one
  # Canonical.transaction_id hash, and the canonical payload emitted
  # two rows sharing one txn_<hex>. Downstream consumers upsert-on-id
  # and silently dropped one leg of every transfer. The fix prefers
  # `legId` so each leg gets a unique canonical id.
  def test_transfer_legs_get_distinct_canonical_ids
    transfer_id = "7c90ac30-5c9f-4dd8-aa4b-9f48390a65b8"
    raw = {
      "wallet"  => {},
      "pockets" => [{ "id" => "p1", "currency" => "EUR", "balance" => 0 }],
      "bank_details" => [],
      "vaults" => [],
      "pocket_transactions" => {
        "p1" => [
          { "id"          => transfer_id,
            "legId"       => "7c90ac30-5c9f-4dd8-0000-9f48390a65b8",
            "startedDate" => 1_536_105_600_000,
            "amount"      => -5086,
            "currency"    => "EUR",
            "description" => "To EUR",
            "type"        => "TRANSFER" },
          { "id"          => transfer_id,
            "legId"       => "7c90ac30-5c9f-4dd8-0001-9f48390a65b8",
            "startedDate" => 1_536_105_600_000,
            "amount"      => 5086,
            "currency"    => "EUR",
            "description" => "From EUR Experimento 1",
            "type"        => "TRANSFER" }
        ]
      }
    }

    payload = normalizer.call(raw)

    assert_equal 2, payload.transactions.size
    ids = payload.transactions.map(&:id)
    assert_equal ids.size, ids.uniq.size,
                 "each leg must hash to a distinct canonical id"
    source_ids = payload.transactions.map(&:source_id)
    assert_includes source_ids, "7c90ac30-5c9f-4dd8-0000-9f48390a65b8"
    assert_includes source_ids, "7c90ac30-5c9f-4dd8-0001-9f48390a65b8"
  end

  # When only `id` is present (no legId), fall back to id so we don't
  # drop the transaction. (Single-leg shape — observed in some
  # historical payloads / non-transfer event types.)
  def test_falls_back_to_id_when_leg_id_missing
    raw = {
      "wallet"  => {},
      "pockets" => [{ "id" => "p1", "currency" => "EUR", "balance" => 0 }],
      "bank_details" => [],
      "vaults" => [],
      "pocket_transactions" => {
        "p1" => [
          { "id"          => "only-id-1",
            "startedDate" => 1_710_504_000_000,
            "amount"      => -100,
            "currency"    => "EUR",
            "description" => "x",
            "type"        => "CARD_PAYMENT" }
        ]
      }
    }
    payload = normalizer.call(raw)
    assert_equal "only-id-1", payload.transactions.first.source_id
  end

  # D1: two passes over the same raw payload must produce byte-identical
  # canonical-id arrays for every entity kind. See
  # simplefreen/reports/freentonic-id-stability-spec.md §Audit evidence —
  # ING was the only provider audited there; this test pins the same
  # property for Revolut in CI against multi-pocket + vault input,
  # including the per-leg source_id path (PR #10), so any future
  # non-idempotent change is caught before it ships.
  def test_ids_are_deterministic_across_multi_record_payload
    raw = {
      "wallet"       => { "id" => "w1" },
      "bank_details" => [
        { "currency" => "EUR", "details" => { "accounts" => [{ "iban" => "LT00 1234 5678 9012 3456" }] } }
      ],
      "cards" => [],
      "pockets" => [
        { "id" => "p-main",  "currency" => "EUR", "balance" => 224_37,
          "name" => "Revolut EUR", "type" => "CURRENT" },
        { "id" => "p-saved", "currency" => "EUR", "balance" => 0,
          "name" => "Experimento 1", "type" => "CURRENT" }
      ],
      "vaults" => [
        { "id" => "vault-1", "name" => "Holiday Fund", "currency" => "EUR",
          "balance" => { "amount" => 350.00, "currency" => "EUR" }, "goal" => 1000.00 }
      ],
      "pocket_transactions" => {
        "p-main" => [
          { "id" => "tr-1", "legId" => "tr-1-debit", "amount" => -1234,
            "startedDate" => 1_710_504_000_000, "currency" => "EUR",
            "description" => "Coffee", "type" => "CARD_PAYMENT" },
          { "id" => "tr-2", "legId" => "tr-2-credit", "amount" => 50_000,
            "startedDate" => 1_710_417_600_000, "currency" => "EUR",
            "description" => "Bank Transfer", "type" => "TRANSFER" }
        ],
        "p-saved" => [
          { "id" => "tr-3", "legId" => "tr-3-debit", "amount" => -100,
            "startedDate" => 1_710_504_000_000, "currency" => "EUR",
            "description" => "Vault top-up", "type" => "TRANSFER" }
        ]
      }
    }
    a = normalizer.call(JSON.parse(JSON.generate(raw)))
    b = normalizer.call(JSON.parse(JSON.generate(raw)))

    refute_empty a.accounts
    refute_empty a.transactions
    assert_equal a.accounts.map(&:id),     b.accounts.map(&:id)
    assert_equal a.transactions.map(&:id), b.transactions.map(&:id)
    assert_equal a.liabilities.map(&:id),  b.liabilities.map(&:id)
  end

  def test_wire_format_money_string_no_cents
    wire = normalizer.call(pocket_raw).to_h
    assert_equal "-12.34", wire["transactions"].first["amount"]
    refute_includes wire.to_s, "_cents"
  end
end

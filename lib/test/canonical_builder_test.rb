require "minitest/autorun"
require "bigdecimal"
require "freentonic"
require_relative "../freentonic/providers/canonical_builder"

class CanonicalBuilderTest < Minitest::Test
  Builder = Freentonic::Providers::CanonicalBuilder

  # --- account_legacy_metadata -------------------------------------------

  def test_account_legacy_metadata_shape
    meta = Builder.account_legacy_metadata(
      legacy_external_id: "ing_live:abc",
      legacy_uids:        ["ing_live:abc"],
      legacy_bank_key:    "ing"
    )
    assert_equal "ing_live:abc",   meta["legacy_external_id"]
    assert_equal ["ing_live:abc"], meta["legacy_uids"]
    assert_equal "ing",            meta["legacy_bank_key"]
  end

  def test_account_legacy_metadata_wraps_scalar_uid_to_array
    meta = Builder.account_legacy_metadata(
      legacy_external_id: "x",
      legacy_uids:        "x",
      legacy_bank_key:    "k"
    )
    assert_equal ["x"], meta["legacy_uids"]
  end

  # --- transaction_legacy_metadata ---------------------------------------

  def test_transaction_legacy_metadata
    meta = Builder.transaction_legacy_metadata(legacy_dedup_key: "ing_live:p:mv")
    assert_equal({ "legacy_dedup_key" => "ing_live:p:mv" }, meta)
  end

  # --- cents_to_amount ---------------------------------------------------

  def test_cents_to_amount_positive
    assert_equal BigDecimal("45.20"), Builder.cents_to_amount(4520)
  end

  def test_cents_to_amount_negative
    assert_equal BigDecimal("-12.34"), Builder.cents_to_amount(-1234)
  end

  def test_cents_to_amount_zero
    assert_equal BigDecimal("0"), Builder.cents_to_amount(0)
  end

  def test_cents_to_amount_nil
    assert_nil Builder.cents_to_amount(nil)
  end

  def test_cents_to_amount_precision_where_float_drifts
    # 99 cents / 100.0 (Float) -> 0.99 exactly today, but e.g. 10/100.0+0.1 drifts.
    # Use a value that exercises BigDecimal precision explicitly.
    bd = Builder.cents_to_amount(1)
    assert_equal BigDecimal("0.01"), bd
    assert_equal "0.01", bd.to_s("F")
  end

  # --- map_status --------------------------------------------------------

  def test_map_status_settled_to_posted
    assert_equal "posted", Builder.map_status("settled")
  end

  def test_map_status_pending_pass_through
    assert_equal "pending", Builder.map_status("pending")
  end

  def test_map_status_nil
    assert_nil Builder.map_status(nil)
  end

  # --- build_account -----------------------------------------------------

  def test_build_account_produces_canonical_entity
    acct = Builder.build_account(
      institution: "ing",
      source_id:   "prod-1",
      currency:    "EUR",
      name:        "My checking",
      type:        "checking",
      iban:        "ES0012345678901234567890",
      balance:     { current: BigDecimal("1234.56"), timestamp: nil },
      metadata:    { "ing_product_type" => 20 },
      legacy_external_id: "ing_live:prod-1",
      legacy_uids:        ["ing_live:prod-1"],
      legacy_bank_key:    "ing"
    )
    assert_kind_of Freentonic::Canonical::Account, acct
    assert_match(/\Aacc_[0-9a-f]{16}\z/, acct.id)
    assert_equal "ing",                  acct.institution
    assert_equal "ES0012345678901234567890", acct.iban
    assert_equal BigDecimal("1234.56"),  acct.balance.current
  end

  def test_build_account_merges_legacy_metadata_on_top
    acct = Builder.build_account(
      institution: "ing",
      source_id:   "p",
      currency:    "EUR",
      metadata:    { "own" => "value", "legacy_bank_key" => "BOGUS" },
      legacy_external_id: "ing_live:p",
      legacy_uids:        ["ing_live:p"],
      legacy_bank_key:    "ing"
    )
    assert_equal "value", acct.metadata["own"]
    assert_equal "ing",   acct.metadata["legacy_bank_key"]   # legacy wins
    assert_equal ["ing_live:p"], acct.metadata["legacy_uids"]
  end

  def test_build_account_stable_ref_overrides_iban_for_id
    # Two accounts with same iban but distinct stable_ref must get
    # different ids (multi-account-per-IBAN case, e.g. Revolut pockets).
    shared = {
      institution: "revolut", currency: "EUR",
      iban: "LT00 1234 5678 9012 3456",
      legacy_external_id: "x", legacy_uids: ["x"], legacy_bank_key: "revolut"
    }
    a = Builder.build_account(**shared, source_id: "pocket:a", stable_ref: "pocket:a")
    b = Builder.build_account(**shared, source_id: "pocket:b", stable_ref: "pocket:b")

    refute_equal a.id, b.id
    assert_equal a.iban, b.iban   # iban still stored for downstream matching
  end

  def test_build_account_id_is_deterministic
    args = {
      institution: "ing", source_id: "p", currency: "EUR",
      legacy_external_id: "ing_live:p", legacy_uids: ["ing_live:p"], legacy_bank_key: "ing"
    }
    a = Builder.build_account(**args)
    b = Builder.build_account(**args)
    assert_equal a.id, b.id
  end

  # --- build_transaction -------------------------------------------------

  def test_build_transaction_produces_canonical_entity
    tx = Builder.build_transaction(
      account_id:      "acc_0123456789abcdef",
      amount:          BigDecimal("-12.34"),
      currency:        "EUR",
      source_id:       "mv-1",
      date:            Date.new(2024, 3, 15),
      raw_description: "COFFEE SHOP",
      description:     "Coffee Shop",
      status:          "posted",
      metadata:        { "ing" => { "uuid" => "mv-1" } },
      legacy_dedup_key: "ing_live:prod-1:mv-1"
    )
    assert_kind_of Freentonic::Canonical::Transaction, tx
    assert_match(/\Atxn_[0-9a-f]{16}\z/, tx.id)
    assert_equal "acc_0123456789abcdef", tx.account_id
    assert_equal BigDecimal("-12.34"),   tx.amount
    assert_equal "ing_live:prod-1:mv-1", tx.metadata["legacy_dedup_key"]
    assert_equal({ "uuid" => "mv-1" }, tx.metadata["ing"])
  end

  def test_build_transaction_id_is_deterministic
    args = {
      account_id: "acc_x", amount: BigDecimal("1"), currency: "EUR",
      date: Date.new(2024, 1, 1), raw_description: "r",
      legacy_dedup_key: "x"
    }
    assert_equal Builder.build_transaction(**args).id,
                 Builder.build_transaction(**args).id
  end

  def test_build_transaction_id_falls_back_to_description_when_raw_missing
    # Should not crash and should still produce a txn_ id when raw_description is nil.
    tx = Builder.build_transaction(
      account_id: "acc_x", amount: BigDecimal("1"), currency: "EUR",
      date: Date.new(2024, 1, 1), description: "cleaned",
      raw_description: nil, legacy_dedup_key: "x"
    )
    assert_match(/\Atxn_[0-9a-f]{16}\z/, tx.id)
  end

  # --- build_liability ---------------------------------------------------

  def test_build_liability_produces_canonical_entity
    liab = Builder.build_liability(
      account_id: "acc_abc",
      type:       "credit_card",
      currency:   "EUR",
      source_id:  "cc-1",
      balance:    BigDecimal("500"),
      limit:      BigDecimal("1500")
    )
    assert_kind_of Freentonic::Canonical::Liability, liab
    assert_match(/\Aliab_[0-9a-f]{16}\z/, liab.id)
    assert_equal "acc_abc",              liab.account_id
    assert_equal "credit_card",          liab.type
    assert_equal BigDecimal("500"),      liab.balance
    assert_equal BigDecimal("1500"),     liab.limit
  end

  # --- payload -----------------------------------------------------------

  def test_payload_wraps_entities_and_injects_scraper_version
    acct = Builder.build_account(
      institution: "ing", source_id: "p", currency: "EUR",
      legacy_external_id: "ing_live:p", legacy_uids: ["ing_live:p"], legacy_bank_key: "ing"
    )
    env = Builder.payload(accounts: [acct], transactions: [], scraper_version: "ing/0.1")
    assert_kind_of Freentonic::Canonical::CanonicalPayload, env
    assert_equal "0.1", env.schema_version
    assert_equal "ing/0.1", env.meta["scraper_version"]
    assert_equal 1, env.accounts.size
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "freentonic"
require_relative "../freentonic/providers/legacy_keys"

class LegacyKeysTest < Minitest::Test
  LegacyKeys = Freentonic::Providers::LegacyKeys

  def setup
    LegacyKeys.__reset_for_tests!
  end

  # ---------- Happy path: plain templates ----------

  def test_simple_string_template
    LegacyKeys.register(:bank,
      account: { external_id: "bank:%{source_id}", uids: ["bank:%{source_id}"], bank_key: "bank" },
      transaction: { dedup_key: "bank:%{tx_id}" }
    )

    out = LegacyKeys.account(institution: :bank, source_id: "abc")
    assert_equal "bank:abc",      out[:legacy_external_id]
    assert_equal ["bank:abc"],    out[:legacy_uids]
    assert_equal "bank",          out[:legacy_bank_key]

    out = LegacyKeys.transaction(institution: :bank, tx_id: "tx-1")
    assert_equal "bank:tx-1", out[:legacy_dedup_key]
  end

  def test_multiple_placeholders_in_one_template
    LegacyKeys.register(:bank,
      account: {
        external_id: "bank:%{bank_id}:%{product_id}",
        uids: ["bank-%{bank_id}-%{product_id}-%{type}"],
        bank_key: "bank_%{bank_id}"
      },
      transaction: { dedup_key: "bank:%{tx_id}" }
    )
    out = LegacyKeys.account(institution: :bank, bank_id: "42", product_id: "9001", type: "ACC")
    assert_equal "bank:42:9001",         out[:legacy_external_id]
    assert_equal ["bank-42-9001-ACC"],   out[:legacy_uids]
    assert_equal "bank_42",              out[:legacy_bank_key]
  end

  # ---------- Conditional (if_<value>) branching ----------

  def test_if_branch_picks_kind_specific_override
    LegacyKeys.register(:bank,
      account: {
        external_id: "bank:%{source_id}",
        uids: {
          default:      ["bank:%{source_id}"],
          if_liability: ["bank-cc-%{source_id}", "bank:%{source_id}"]
        },
        bank_key: { default: "bank", if_liability: "bank_cc" }
      },
      transaction: { dedup_key: "bank:%{tx_id}" }
    )

    asset = LegacyKeys.account(institution: :bank, source_id: "a", kind: "asset")
    assert_equal ["bank:a"], asset[:legacy_uids]
    assert_equal "bank",     asset[:legacy_bank_key]

    liab = LegacyKeys.account(institution: :bank, source_id: "a", kind: "liability")
    assert_equal ["bank-cc-a", "bank:a"], liab[:legacy_uids]
    assert_equal "bank_cc",               liab[:legacy_bank_key]
  end

  def test_if_branch_falls_back_to_default_when_no_match
    LegacyKeys.register(:bank,
      account: {
        external_id: "bank:%{source_id}",
        uids:        ["bank:%{source_id}"],
        bank_key: { default: "bank", if_liability: "bank_cc" }
      },
      transaction: { dedup_key: "bank:%{tx_id}" }
    )
    out = LegacyKeys.account(institution: :bank, source_id: "x", kind: "asset")
    assert_equal "bank", out[:legacy_bank_key]
  end

  def test_missing_default_raises_loudly_when_no_branch_matches
    LegacyKeys.register(:bank,
      account: {
        external_id: "bank:%{source_id}",
        uids:        ["bank:%{source_id}"],
        bank_key: { if_liability: "bank_cc" }  # no default:
      },
      transaction: { dedup_key: "bank:%{tx_id}" }
    )
    err = assert_raises(LegacyKeys::InvalidConfigError) do
      LegacyKeys.account(institution: :bank, source_id: "x", kind: "asset")
    end
    assert_match(/no matching if_/, err.message)
  end

  # ---------- Template errors ----------

  def test_missing_placeholder_raises_invalid_config_error
    LegacyKeys.register(:bank,
      account: {
        external_id: "bank:%{source_id}:%{missing_field}",
        uids:        ["bank:%{source_id}"],
        bank_key:    "bank"
      },
      transaction: { dedup_key: "bank:%{tx_id}" }
    )
    err = assert_raises(LegacyKeys::InvalidConfigError) do
      LegacyKeys.account(institution: :bank, source_id: "x")
    end
    assert_match(/missing placeholder/, err.message)
  end

  def test_unknown_institution_raises
    err = assert_raises(LegacyKeys::InvalidConfigError) do
      LegacyKeys.account(institution: :nope, source_id: "x")
    end
    assert_match(/no LegacyKeys config registered/, err.message)
  end

  # ---------- Security: reject non-data values at register time ----------

  def test_rejects_proc_in_config
    err = assert_raises(LegacyKeys::InvalidConfigError) do
      LegacyKeys.register(:bad,
        account: {
          external_id: ->(source_id:) { "haha:#{source_id}" },
          uids:        ["x"],
          bank_key:    "b"
        },
        transaction: { dedup_key: "d" }
      )
    end
    assert_match(/type Proc/, err.message)
  end

  def test_rejects_symbol_as_value
    err = assert_raises(LegacyKeys::InvalidConfigError) do
      LegacyKeys.register(:bad,
        account: {
          external_id: :some_symbol,
          uids:        ["x"],
          bank_key:    "b"
        },
        transaction: { dedup_key: "d" }
      )
    end
    assert_match(/type Symbol/, err.message)
  end

  def test_rejects_unknown_hash_key
    err = assert_raises(LegacyKeys::InvalidConfigError) do
      LegacyKeys.register(:bad,
        account: {
          external_id: "x",
          uids:        ["x"],
          bank_key:    { default: "a", weird_key: "b" }
        },
        transaction: { dedup_key: "d" }
      )
    end
    assert_match(/weird_key/, err.message)
    assert_match(/not permitted/, err.message)
  end

  def test_rejects_nested_proc_inside_array
    err = assert_raises(LegacyKeys::InvalidConfigError) do
      LegacyKeys.register(:bad,
        account: {
          external_id: "x",
          uids:        ["ok", ->(**) { "oops" }],
          bank_key:    "b"
        },
        transaction: { dedup_key: "d" }
      )
    end
    assert_match(/type Proc/, err.message)
  end
end

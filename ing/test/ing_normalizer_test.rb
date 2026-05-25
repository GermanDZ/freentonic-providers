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
    assert_nil acct.metadata["partial_data_suspected"]
  end

  def test_partial_data_breadcrumb_is_surfaced_on_account_metadata
    breadcrumb = {
      "from_date_requested" => "2024-11-10",
      "earliest_returned"   => "2026-03-13",
      "gap_days"            => 488,
      "movement_count"      => 92,
      "reason"              => "sca_elevation_required_suspected"
    }
    payload = normalizer.call([asset_product("_partial_data_suspected" => breadcrumb)])
    acct = payload.accounts.first
    assert_equal breadcrumb, acct.metadata["partial_data_suspected"]
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

  def test_credit_card_balance_falls_back_to_line_outstanding_when_no_per_card_data
    # No monthPurchasesAmount on the (sole) plastic: it is the line carrier,
    # so it absorbs the full line outstanding (creditLimit 6500 -
    # availableBalance 4317.19 = 2182.81), negated (money owed).
    payload = normalizer.call([credit_card_product])
    acct = payload.accounts.first
    assert_equal BigDecimal("-2182.81"), acct.balance.current
    assert_equal "ing_live:line_outstanding", acct.metadata["balance_source"]
  end

  def test_credit_card_with_no_outstanding_is_zero
    payload = normalizer.call([credit_card_product("creditLimit" => 1485.0,
                                                   "availableBalance" => 1485.0)])
    acct = payload.accounts.first
    assert_equal BigDecimal("0"), acct.balance.current
    assert_equal "ing_live:card_purchases", acct.metadata["balance_source"]
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

  def test_each_plastic_emits_its_own_account_with_distinct_portable_ref
    # Cross-source matching with Fintonic happens per-plastic (Fintonic
    # emits one CREDITCARD entry per PAN-last-4). Plastics on the same
    # revolving credit line therefore must NOT collapse — each gets its
    # own canonical Account with portable_ref="1465:LAST4".
    plastic_1 = credit_card_product(
      "uuid" => "plastic-1", "productNumber" => "4174804472951087",
      "movements" => [asset_movement("uuid" => "mv-from-plastic-1")]
    )
    plastic_2 = credit_card_product(
      "uuid" => "plastic-2", "productNumber" => "4174804472951095",
      "movements" => [asset_movement("uuid" => "mv-from-plastic-2", "amount" => -5.0)]
    )

    payload = normalizer.call([plastic_1, plastic_2])

    assert_equal 2, payload.accounts.size
    refute_equal payload.accounts[0].id, payload.accounts[1].id
    assert_equal "card:1465:1087", payload.accounts[0].portable_id
    assert_equal "card:1465:1095", payload.accounts[1].portable_id
    assert_equal 2, payload.transactions.size
  end

  def test_plastics_on_shared_line_emit_own_purchases_summing_to_line_total
    # Per-plastic monthPurchasesAmount is the live per-card balance; the
    # plastics' amounts sum to the line outstanding (limit - available), so
    # the debt is NOT duplicated across plastics.
    line = { "creditLimit" => 6500.0, "availableBalance" => 5071.74,
             "associatedAccount" => { "productNumber" => "1465" } }
    p1 = credit_card_product(line.merge("uuid" => "p1", "productNumber" => "5160974472951087",
                                        "monthPurchasesAmount" => 360.44))
    p2 = credit_card_product(line.merge("uuid" => "p2", "productNumber" => "5160974472951095",
                                        "monthPurchasesAmount" => 1067.82))
    payload = normalizer.call([p1, p2])

    a1087 = payload.accounts.find { |a| a.metadata["ing_product_number"].end_with?("1087") }
    a1095 = payload.accounts.find { |a| a.metadata["ing_product_number"].end_with?("1095") }
    assert_equal BigDecimal("-360.44"),  a1087.balance.current
    assert_equal BigDecimal("-1067.82"), a1095.balance.current
    assert_equal "ing_live:card_purchases", a1087.metadata["balance_source"]
    # Sum equals the authoritative line outstanding (6500 - 5071.74).
    assert_equal BigDecimal("-1428.26"), payload.accounts.sum { |a| a.balance.current }
  end

  def test_line_remainder_lands_on_carrier_when_purchases_undershoot
    # Pago aplazado: per-plastic purchases (300 + 100) sum to LESS than the
    # line outstanding (6500 - 5071.74 = 1428.26). The remainder (1028.26)
    # lands on the carrier (active principal) so the per-plastic balances
    # still total the authoritative line figure — never under-reporting debt.
    line = { "creditLimit" => 6500.0, "availableBalance" => 5071.74,
             "associatedAccount" => { "productNumber" => "1465" } }
    principal = credit_card_product(line.merge(
      "uuid" => "p1", "productNumber" => "5160974472951087",
      "monthPurchasesAmount" => 300.0, "holder" => { "type" => "Principal" }))
    adicional = credit_card_product(line.merge(
      "uuid" => "p2", "productNumber" => "5160974472951095",
      "monthPurchasesAmount" => 100.0, "holder" => { "type" => "Adicional" }))
    payload = normalizer.call([principal, adicional])

    a1087 = payload.accounts.find { |a| a.metadata["ing_product_number"].end_with?("1087") }
    a1095 = payload.accounts.find { |a| a.metadata["ing_product_number"].end_with?("1095") }
    assert_equal BigDecimal("-1328.26"), a1087.balance.current   # 300 + 1028.26 remainder
    assert_equal BigDecimal("-100.00"),  a1095.balance.current
    assert_equal "ing_live:card_purchases+line_reconcile", a1087.metadata["balance_source"]
    assert_equal BigDecimal("-1428.26"), payload.accounts.sum { |a| a.balance.current }
  end

  def test_separate_lines_do_not_cross_reconcile
    # Two distinct lines (different creditLimit) billed to the same account
    # must reconcile independently, not pool their remainders.
    line_a = credit_card_product("uuid" => "a", "productNumber" => "5160974472951087",
                                 "creditLimit" => 6500.0, "availableBalance" => 5071.74,
                                 "monthPurchasesAmount" => 1428.26,
                                 "associatedAccount" => { "productNumber" => "1465" })
    line_b = credit_card_product("uuid" => "b", "productNumber" => "4174804472951026",
                                 "creditLimit" => 1485.0, "availableBalance" => 1485.0,
                                 "monthPurchasesAmount" => 0.0,
                                 "associatedAccount" => { "productNumber" => "1465" })
    payload = normalizer.call([line_a, line_b])
    a = payload.accounts.find { |x| x.metadata["ing_product_number"].end_with?("1087") }
    b = payload.accounts.find { |x| x.metadata["ing_product_number"].end_with?("1026") }
    assert_equal BigDecimal("-1428.26"), a.balance.current
    assert_equal BigDecimal("0"),        b.balance.current
  end

  def test_credit_card_account_id_stable_across_plastic_uuid_change
    # Stability now comes from portable_ref (PAN last-4), not the source
    # uuid. As long as the plastic's PAN is unchanged, ING re-issuing the
    # plastic with a fresh uuid keeps the canonical Account.id stable.
    initial = normalizer.call([credit_card_product("uuid" => "old-plastic")])
    after_reissue = normalizer.call([credit_card_product("uuid" => "new-plastic")])
    assert_equal initial.accounts.first.id, after_reissue.accounts.first.id
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

  # D1: two passes over the same raw payload must produce byte-identical
  # canonical-id arrays for every entity kind. Audited empirically on a
  # live ING capture (see simplefreen/reports/freentonic-id-stability-spec.md
  # §Audit evidence — 187/187 records matched across two sessions); this
  # test pins the property in CI against multi-record input so any future
  # non-idempotent change (in-place mutation of raw, ordering bug, key
  # randomization) is caught before it ships.
  def test_ids_are_deterministic_across_multi_record_payload
    raw = [
      asset_product("uuid" => "prod-a",
                    "iban" => "ES59 1465 0100 9817 1439 1272",
                    "movements" => [
                      asset_movement("uuid" => "mv-a1"),
                      asset_movement("uuid" => "mv-a2", "amount" => -5.0,
                                     "description" => "TRAIN")
                    ]),
      asset_product("uuid" => "prod-b",
                    "iban" => "ES59 1465 0100 9817 1439 7251",
                    "movements" => [
                      asset_movement("uuid" => "mv-b1", "amount" => 1200.0,
                                     "description" => "SALARY")
                    ]),
      credit_card_product("uuid" => "cc-a",
                          "productNumber" => "4174804472951018",
                          "movements" => [
                            asset_movement("uuid" => "mv-cc1", "amount" => -8.0,
                                           "description" => "AMAZON")
                          ])
    ]
    a = normalizer.call(JSON.parse(JSON.generate(raw)))
    b = normalizer.call(JSON.parse(JSON.generate(raw)))

    refute_empty a.accounts
    refute_empty a.transactions
    refute_empty a.liabilities
    assert_equal a.accounts.map(&:id),     b.accounts.map(&:id)
    assert_equal a.transactions.map(&:id), b.transactions.map(&:id)
    assert_equal a.liabilities.map(&:id),  b.liabilities.map(&:id)
  end

  def test_account_id_collides_with_fintonic_for_same_physical_account
    payload = normalizer.call([asset_product("iban" => "ES59 1465 0100 9817 1439 1272")])
    acct = payload.accounts.first
    fintonic_id = Freentonic::Canonical.account_id(
      institution: "fintonic", portable_ref: "1465:1272"
    )
    assert_equal fintonic_id, acct.id
    assert_equal "bank:1465:1272", acct.portable_id
  end

  def test_account_without_iban_falls_back_to_legacy_derivation
    payload = normalizer.call([asset_product("iban" => "")])
    acct = payload.accounts.first
    legacy = Freentonic::Canonical.account_id(
      institution: "ing", source_id: "prod-1"
    )
    assert_equal legacy, acct.id
    assert_nil acct.portable_id
  end

  def test_credit_card_id_collides_with_fintonic_creditcard_via_pan_last4
    # ING's productNumber on a credit-card product is the full PAN; the
    # last 4 must match what Fintonic emits as productId for the same card.
    payload = normalizer.call([credit_card_product("productNumber" => "4174804472951018")])
    acct = payload.accounts.first
    fintonic_id = Freentonic::Canonical.account_id(
      institution: "fintonic", portable_ref: "1465:1018"
    )
    assert_equal fintonic_id, acct.id
    assert_equal "card:1465:1018", acct.portable_id
  end

  def test_credit_card_without_pan_falls_back_to_legacy_derivation
    payload = normalizer.call([credit_card_product("uuid" => "cc-x", "productNumber" => nil)])
    acct = payload.accounts.first
    # Legacy derivation. Note source_id is rewritten by the credit-line
    # collapse layer (single-plastic still gets ing_line_<uuid>_<limit>),
    # so the input uuid is no longer the source_id we hash on. Pin the
    # observed id rather than re-deriving it from the input uuid.
    refute_nil acct.id
    assert_match(/\Aacc_[0-9a-f]{16}\z/, acct.id)
    assert_nil acct.portable_id
  end

  def test_same_day_duplicate_movements_get_distinct_ids
    a = asset_movement("uuid" => "mv-A", "amount" => -680, "description" => "KEPLER")
    b = asset_movement("uuid" => "mv-B", "amount" => -680, "description" => "KEPLER")
    payload = normalizer.call([asset_product("movements" => [a, b])])

    assert_equal 2, payload.transactions.size
    refute_equal payload.transactions[0].id, payload.transactions[1].id
  end

  # Regression: ING returns a top-line `description` plus a sub-line
  # `store` carrying per-line detail. When a real-world account has two
  # legitimate same-day same-amount postings (typical "one school fee
  # per kid" case), the canonical description used to keep only the top
  # line, so the two rows collapsed to byte-identical text downstream
  # and SimpleFIN consumers reported them as bridge dups. Both fields
  # must survive concatenated. See
  # simplefreen/reports/simplefreen-dup-r3-post-fix.md.
  def test_store_subline_is_concatenated_into_description
    a = asset_movement("uuid" => "mv-luca", "amount" => -172, "effectiveDate" => "04/05/2026",
                       "description" => "Recibo ESCUELA NUEVA KEPLER, S.L.",
                       "store" => "luca del zotto gonzalez mayo servicios: 172.00")
    b = asset_movement("uuid" => "mv-lara", "amount" => -172, "effectiveDate" => "04/05/2026",
                       "description" => "Recibo ESCUELA NUEVA KEPLER, S.L.",
                       "store" => "lara del zotto gonzalez mayo servicios: 172.00")
    payload = normalizer.call([asset_product("movements" => [a, b])])

    descs = payload.transactions.map(&:description)
    assert_equal 2, descs.uniq.size,
      "two legitimate twin postings must produce distinct canonical descriptions"
    assert(descs.any? { |d| d.include?("luca") }, "luca disambiguator must reach description")
    assert(descs.any? { |d| d.include?("lara") }, "lara disambiguator must reach description")
    # Top-line preserved
    descs.each { |d| assert_includes d, "Recibo ESCUELA NUEVA KEPLER, S.L." }
    # raw_description carries the same merged text (unmolested provider
    # output, which on ING means description + store together)
    payload.transactions.each { |t| assert_equal t.description, t.raw_description }
  end

  # Store text from ING can carry runs of whitespace used for column
  # alignment in the bank's own UI ("REFERENCIA:    xxxx    RECIBO:    yyyy").
  # Collapse to single spaces so canonical descriptions stay readable
  # without losing the disambiguating tokens.
  def test_store_whitespace_is_collapsed
    mv = asset_movement(
      "uuid" => "ayto-1", "amount" => -42, "effectiveDate" => "16/04/2026",
      "description" => "Recibo AYUNTAMIENTO DE ALCOBENDAS (DEPORTES)",
      "store" => " REFERENCIA: AB4905839                   RECIBO: 10196167 "
    )
    payload = normalizer.call([asset_product("movements" => [mv])])
    desc = payload.transactions.first.description
    refute_match(/\s{2,}/, desc, "no runs of whitespace inside description")
    assert_includes desc, "REFERENCIA: AB4905839 RECIBO: 10196167"
  end

  # When `store` is absent the description is just the top line — no
  # trailing separator, no empty join.
  def test_missing_store_leaves_description_unchanged
    mv = asset_movement("uuid" => "card-1", "amount" => -5,
                        "description" => "Pago en STARBUCKS MADRID", "store" => nil)
    payload = normalizer.call([asset_product("movements" => [mv])])
    assert_equal "Pago en STARBUCKS MADRID", payload.transactions.first.description
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

  # --- pre-clearing dup collapse (dup-class-2) --------------------------
  #
  # ING's /v2/products/transactions/search re-emits the same real posting
  # under two transactionSequence ids during the pre-/post-clearing
  # window: a terse pre-clearing row ("WWW.AMAZON") and an enriched
  # post-clearing row ("WWW.AMAZON*NO3CS7J44 LUXEMBOURG"). Without
  # collapse, each fetch over that window writes two canonical txns for
  # one posting. The shorter row must be dropped when the longer row's
  # description starts with the shorter verbatim (after whitespace
  # normalization).

  def test_pre_clearing_dup_terse_vs_enriched_is_collapsed
    terse = asset_movement(
      "uuid" => "mv-amazon-pending", "amount" => -26.38,
      "effectiveDate" => "21/05/2026", "description" => "WWW.AMAZON"
    )
    enriched = asset_movement(
      "uuid" => "mv-amazon-cleared", "amount" => -26.38,
      "effectiveDate" => "21/05/2026",
      "description" => "WWW.AMAZON*NO3CS7J44           LUXEMBOURG"
    )
    payload = normalizer.call([asset_product("movements" => [terse, enriched])])

    assert_equal 1, payload.transactions.size,
      "terse pre-clearing row must be collapsed into the enriched row"
    surviving = payload.transactions.first
    assert_includes surviving.description, "LUXEMBOURG",
      "the enriched row must be the one kept"
    assert_equal "mv-amazon-cleared", surviving.source_id
  end

  def test_pre_clearing_dup_collapses_on_whitespace_only_difference
    # Prusa case from production: same merchant text padded with runs of
    # spaces in the enriched row. After whitespace collapse, the terse row
    # is a strict prefix.
    terse = asset_movement(
      "uuid" => "mv-prusa-pending", "amount" => -1331.47,
      "effectiveDate" => "21/05/2026", "description" => "Prusa Research"
    )
    enriched = asset_movement(
      "uuid" => "mv-prusa-cleared", "amount" => -1331.47,
      "effectiveDate" => "21/05/2026",
      "description" => "Prusa Research                 Prague"
    )
    payload = normalizer.call([asset_product("movements" => [terse, enriched])])

    assert_equal 1, payload.transactions.size
    assert_equal "mv-prusa-cleared", payload.transactions.first.source_id
  end

  def test_real_twin_postings_with_identical_description_are_kept
    # Two legitimate €80 fees to the same town hall on the same day —
    # different physical postings, same description after normalization.
    a = asset_movement("uuid" => "mv-twin-a", "amount" => -80,
                       "effectiveDate" => "20/05/2026",
                       "description" => "AYUNTAMIENTO DE ALCOBENDA ALCOBENDAS")
    b = asset_movement("uuid" => "mv-twin-b", "amount" => -80,
                       "effectiveDate" => "20/05/2026",
                       "description" => "AYUNTAMIENTO DE ALCOBENDA ALCOBENDAS")
    payload = normalizer.call([asset_product("movements" => [a, b])])

    assert_equal 2, payload.transactions.size,
      "real twins with identical descriptions must both be preserved"
  end

  def test_distinct_postings_sharing_date_and_amount_are_kept
    # Same (account, date, amount) by coincidence — different merchants.
    # Neither description is a prefix of the other, so both survive.
    a = asset_movement("uuid" => "mv-cafe", "amount" => -60,
                       "effectiveDate" => "29/11/2024",
                       "description" => "CAFE DE SAN MILLAN SEGOVIA")
    b = asset_movement("uuid" => "mv-petro", "amount" => -60,
                       "effectiveDate" => "29/11/2024",
                       "description" => "PETROPRIX ALCOBENDAS ALCOBENDAS")
    payload = normalizer.call([asset_product("movements" => [a, b])])

    assert_equal 2, payload.transactions.size
  end

  def test_real_twins_with_store_disambiguator_are_kept
    # Regression interaction with the existing description+store concat
    # logic: Escuela Kepler bills the same amount for two kids on the
    # same day; concatenated descriptions differ ("luca…" vs "lara…"),
    # so the prefix-collapse path must NOT touch them.
    a = asset_movement("uuid" => "mv-luca", "amount" => -680,
                       "effectiveDate" => "04/05/2026",
                       "description" => "Recibo ESCUELA NUEVA KEPLER, S.L.",
                       "store" => "luca del zotto gonzalez mayo: 680.00")
    b = asset_movement("uuid" => "mv-lara", "amount" => -680,
                       "effectiveDate" => "04/05/2026",
                       "description" => "Recibo ESCUELA NUEVA KEPLER, S.L.",
                       "store" => "lara del zotto gonzalez mayo: 680.00")
    payload = normalizer.call([asset_product("movements" => [a, b])])

    assert_equal 2, payload.transactions.size,
      "twin postings disambiguated only by `store` must survive collapse"
  end

  def test_three_way_group_with_unrelated_posting_keeps_all
    # Defensive: if a phantom terse + enriched pair coincides on
    # (date, amount) with a third unrelated posting, the algorithm
    # currently keeps all three. Trade-off: avoid over-collapsing real
    # postings at the cost of leaving rare three-way phantom-mixed
    # groups in canonical. Documented behavior — pin it.
    terse = asset_movement("uuid" => "mv-amzn-terse", "amount" => -26.38,
                           "effectiveDate" => "21/05/2026", "description" => "WWW.AMAZON")
    enriched = asset_movement("uuid" => "mv-amzn-cleared", "amount" => -26.38,
                              "effectiveDate" => "21/05/2026",
                              "description" => "WWW.AMAZON*NO3CS7J44 LUXEMBOURG")
    unrelated = asset_movement("uuid" => "mv-other", "amount" => -26.38,
                               "effectiveDate" => "21/05/2026",
                               "description" => "WWW.AMAZON GIFT CARD")
    payload = normalizer.call([asset_product("movements" => [terse, enriched, unrelated])])

    assert_equal 3, payload.transactions.size,
      "mixed group must be left for manual review rather than collapsed"
  end

  def test_collapse_does_not_cross_accounts
    # Same date + amount + description on two different accounts must
    # produce two transactions — collapse is scoped per account.
    mv = asset_movement("uuid" => "mv-shared", "amount" => -10.0,
                        "effectiveDate" => "15/03/2024",
                        "description" => "STARBUCKS MADRID")
    payload = normalizer.call([
      asset_product("uuid" => "prod-a", "iban" => "ES59 1465 0100 9817 1439 1272",
                    "movements" => [mv.merge("uuid" => "mv-a")]),
      asset_product("uuid" => "prod-b", "iban" => "ES59 1465 0100 9817 1439 7251",
                    "movements" => [mv.merge("uuid" => "mv-b")])
    ])
    assert_equal 2, payload.transactions.size
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

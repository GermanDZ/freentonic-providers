# frozen_string_literal: true

require "bigdecimal"
require "freentonic"

module Freentonic
  module Providers
    # Shared construction logic for canonical-shaped provider normalizers.
    #
    # Every provider emits the same four entity kinds (Account, Transaction,
    # Liability, and the outer CanonicalPayload), and every provider must
    # also carry a set of legacy-compatibility strings inside metadata during
    # the receiver-side transition window (legacy_external_id, legacy_uids,
    # legacy_bank_key on accounts; legacy_dedup_key on transactions). This
    # module centralizes that so per-provider normalizers only describe
    # what's actually provider-specific: field mapping and the legacy
    # string formulas.
    #
    # Module-function style: pure factories, no state. Each factory returns
    # a frozen Freentonic::Canonical entity value object.
    module CanonicalBuilder
      module_function

      # --- Legacy-compat metadata (transition window) ----------------------
      #
      # Providers pass the exact strings the old normalizer would have
      # emitted; this module does not try to infer them, so bit-exact
      # equivalence is the caller's responsibility (and guaranteed by tests).

      def account_legacy_metadata(legacy_external_id:, legacy_uids:, legacy_bank_key:)
        {
          "legacy_external_id" => legacy_external_id,
          "legacy_uids"        => Array(legacy_uids),
          "legacy_bank_key"    => legacy_bank_key
        }
      end

      def transaction_legacy_metadata(legacy_dedup_key:)
        { "legacy_dedup_key" => legacy_dedup_key }
      end

      # --- Value coercions -------------------------------------------------

      # Integer cents → BigDecimal major units. nil-safe.
      # Avoids Float because cents/100.0 drifts at edges (e.g., 0.1 + 0.2).
      def cents_to_amount(cents)
        return nil if cents.nil?
        BigDecimal(cents.to_s) / 100
      end

      # Legacy "settled"/"pending"/nil → canonical "posted"/"pending"/nil.
      def map_status(old_pending_status)
        case old_pending_status
        when "settled" then Freentonic::Canonical::Transaction::POSTED
        when "pending" then Freentonic::Canonical::Transaction::PENDING
        else old_pending_status
        end
      end

      # --- Entity factories ------------------------------------------------

      # Build a Canonical::Account. Computes id via Canonical.account_id,
      # merges legacy-compat metadata on top of the caller's metadata
      # (legacy keys win, so providers can't accidentally blank them out).
      def build_account(institution:, source_id:, currency:,
                        name: nil, type: nil, iban: nil, balance: nil,
                        metadata: {},
                        legacy_external_id:, legacy_uids:, legacy_bank_key:)
        id = Freentonic::Canonical.account_id(
          institution: institution,
          iban: iban,
          source_id: source_id,
          name: name
        )
        merged_metadata = (metadata || {}).merge(
          account_legacy_metadata(
            legacy_external_id: legacy_external_id,
            legacy_uids: legacy_uids,
            legacy_bank_key: legacy_bank_key
          )
        )
        Freentonic::Canonical::Account.new(
          id:          id,
          source_id:   source_id,
          institution: institution,
          name:        name,
          type:        type,
          currency:    currency,
          iban:        iban,
          balance:     balance,
          metadata:    merged_metadata
        )
      end

      # Build a Canonical::Transaction. Computes id via Canonical.transaction_id.
      # If raw_description is nil, falls back to description for id stability —
      # the cleaned description is at least as stable as "nothing".
      def build_transaction(account_id:, amount:, currency:,
                            source_id: nil, date: nil, value_date: nil,
                            description: nil, raw_description: nil,
                            status: nil, merchant: nil, category: nil,
                            metadata: {}, legacy_dedup_key:)
        id = Freentonic::Canonical.transaction_id(
          account_id:      account_id,
          date:            date,
          amount:          amount,
          raw_description: raw_description || description
        )
        merged_metadata = (metadata || {}).merge(
          transaction_legacy_metadata(legacy_dedup_key: legacy_dedup_key)
        )
        Freentonic::Canonical::Transaction.new(
          id:              id,
          source_id:       source_id,
          account_id:      account_id,
          amount:          amount,
          currency:        currency,
          date:            date,
          value_date:      value_date,
          description:     description,
          raw_description: raw_description,
          status:          status,
          merchant:        merchant,
          category:        category,
          metadata:        merged_metadata
        )
      end

      # Build a Canonical::Liability attached to a canonical Account.id.
      # sub_ref disambiguates multiple liabilities of the same type on the
      # same account (not common, but required by Canonical.liability_id).
      def build_liability(account_id:, type:, currency:,
                          source_id: nil, balance: nil, limit: nil,
                          due_date: nil, metadata: {}, sub_ref: nil)
        id = Freentonic::Canonical.liability_id(
          account_id: account_id,
          type:       type,
          sub_ref:    sub_ref
        )
        Freentonic::Canonical::Liability.new(
          id:         id,
          source_id:  source_id,
          type:       type,
          account_id: account_id,
          balance:    balance,
          limit:      limit,
          currency:   currency,
          due_date:   due_date,
          metadata:   metadata || {}
        )
      end

      # Wrap entity arrays into the outer envelope with a conventional
      # meta.scraper_version. Callers who need more meta keys can build
      # the payload directly via Freentonic::Canonical::CanonicalPayload.new.
      def payload(accounts:, transactions:, liabilities: [], scraper_version:)
        Freentonic::Canonical::CanonicalPayload.new(
          accounts:     accounts,
          transactions: transactions,
          liabilities:  liabilities,
          meta:         { "scraper_version" => scraper_version }
        )
      end
    end
  end
end

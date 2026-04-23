# frozen_string_literal: true

module Freentonic
  module Providers
    # Declarative, data-only registry for the legacy-compatibility metadata
    # that canonical providers emit during the receiver cutover window
    # (legacy_external_id / legacy_uids / legacy_bank_key on accounts;
    # legacy_dedup_key on transactions).
    #
    # Security intent: the config a provider supplies here MUST be plain
    # data — Strings, Arrays of Strings, Hashes of either. Procs, Symbols,
    # and any other callable are rejected at register time. This keeps the
    # per-provider surface that can be reviewed for malicious code as small
    # as possible: if you're auditing a provider PR, the LegacyKeys.register
    # block is visibly data and the normalizer body is the only place Ruby
    # can run.
    #
    # Template substitution uses Ruby's native `String#%` with named
    # placeholders (`"foo:%{bar}"` + `{bar: "x"}` → `"foo:x"`), which is
    # pure string interpolation — no eval, no format-string tricks, no
    # shelling out. A missing placeholder raises KeyError loudly.
    #
    # Branching: a value may be a Hash with a `default:` key and any number
    # of `if_<discriminator>:` keys. The caller passes a discriminator
    # kwarg (e.g. `kind:`) and the resolver picks `if_<value>` when
    # present, otherwise `default`. This covers every branch across the
    # four shipped providers without any callables.
    #
    #   LegacyKeys.register(:ing,
    #     account: {
    #       external_id: "ing_live:%{source_id}",
    #       uids: {
    #         default:      ["ing_live:%{source_id}"],
    #         if_liability: ["ing-cc-%{source_id}", "ing_live:%{source_id}"]
    #       },
    #       bank_key: { default: "ing", if_liability: "ing_cc" }
    #     },
    #     transaction: {
    #       dedup_key: "ing_live:%{account_source_id}:%{tx_source_id}"
    #     }
    #   )
    #
    # Call site:
    #
    #   Builder.build_account(
    #     ...,
    #     **LegacyKeys.account(institution: "ing", source_id: uuid, kind: kind)
    #   )
    class LegacyKeys
      class InvalidConfigError < StandardError; end

      # Keys that trigger conditional resolution. The discriminator kwarg
      # name is encoded in the hash key itself: `if_<discriminator_value>`.
      DEFAULT_KEY = :default

      @configs = {}

      class << self
        def register(institution, account:, transaction:)
          validate_spec!(account, location: "#{institution}.account")
          validate_spec!(transaction, location: "#{institution}.transaction")
          @configs[institution.to_sym] = { account: account, transaction: transaction }.freeze
          nil
        end

        # Returns the three-key Hash accepted by CanonicalBuilder#build_account
        # and #build_liability: legacy_external_id, legacy_uids, legacy_bank_key.
        def account(institution:, **args)
          cfg = config_for(institution).fetch(:account)
          {
            legacy_external_id: resolve!(cfg.fetch(:external_id), args, "account.external_id"),
            legacy_uids:        Array(resolve!(cfg.fetch(:uids), args, "account.uids")),
            legacy_bank_key:    resolve!(cfg.fetch(:bank_key), args, "account.bank_key")
          }
        end

        # Returns { legacy_dedup_key: "..." } for CanonicalBuilder#build_transaction.
        def transaction(institution:, **args)
          cfg = config_for(institution).fetch(:transaction)
          { legacy_dedup_key: resolve!(cfg.fetch(:dedup_key), args, "transaction.dedup_key") }
        end

        # Accessor for tests + introspection. Returns a frozen hash.
        def config_for(institution)
          @configs[institution.to_sym] or
            raise InvalidConfigError, "no LegacyKeys config registered for #{institution.inspect}"
        end

        # Reset for tests. Not intended for production use.
        def __reset_for_tests!
          @configs = {}
        end

        private

        def resolve!(spec, args, location)
          case spec
          when String
            interpolate(spec, args, location)
          when Array
            spec.map.with_index { |item, i| resolve!(item, args, "#{location}[#{i}]") }
          when Hash
            branch = pick_branch(spec, args, location)
            resolve!(branch, args, location)
          when nil
            nil
          else
            raise InvalidConfigError, "#{location}: unexpected value #{spec.inspect}"
          end
        end

        def pick_branch(spec, args, location)
          # Find an `if_<value>:` key matching any of the caller's args.
          args.each do |discriminator, value|
            candidate = :"if_#{value}"
            return spec[candidate] if spec.key?(candidate)
          end
          spec.fetch(DEFAULT_KEY) do
            raise InvalidConfigError,
                  "#{location}: no matching if_<value> branch and no default: key " \
                  "(args: #{args.inspect}, keys: #{spec.keys.inspect})"
          end
        end

        def interpolate(template, args, location)
          template % args
        rescue KeyError => e
          raise InvalidConfigError,
                "#{location}: template #{template.inspect} references missing placeholder #{e.message}"
        end

        # Validation at register time — reject anything that isn't pure
        # data. The allowlist is deliberately tight: String, Array,
        # Hash (with further recursion), nil. No Proc, no Symbol values,
        # no Method, no custom objects.
        def validate_spec!(spec, location:)
          case spec
          when String, nil
            nil
          when Array
            spec.each_with_index { |item, i| validate_spec!(item, location: "#{location}[#{i}]") }
          when Hash
            spec.each do |key, value|
              unless key.is_a?(Symbol) && (key == DEFAULT_KEY || key.to_s.start_with?("if_") || leaf_key?(key))
                raise InvalidConfigError,
                      "#{location}: hash key #{key.inspect} is not permitted " \
                      "(allowed: :default, :if_<value>, or a leaf field name)"
              end
              validate_spec!(value, location: "#{location}.#{key}")
            end
          else
            raise InvalidConfigError,
                  "#{location}: value of type #{spec.class} is not permitted; " \
                  "use String / Array / Hash (default+if_<value>) only"
          end
        end

        # Leaf keys are the per-entity-type field names (external_id, uids,
        # bank_key, dedup_key). They appear as Hash keys at the top level
        # of an account/transaction block.
        LEAF_KEYS = %i[external_id uids bank_key dedup_key].freeze

        def leaf_key?(key)
          LEAF_KEYS.include?(key)
        end
      end
    end
  end
end

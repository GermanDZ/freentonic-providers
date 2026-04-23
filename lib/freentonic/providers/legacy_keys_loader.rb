# frozen_string_literal: true

require "yaml"
require_relative "legacy_keys"

module Freentonic
  module Providers
    # Auto-discovers per-provider `legacy.yml` files living next to a
    # workflow.yml and registers them with LegacyKeys. Called once at
    # boot from each provider's normalizer.rb (or once globally — the
    # registration is idempotent).
    #
    # Security posture (belt-and-braces):
    #
    # 1. Parser: YAML.safe_load with `permitted_classes: []` refuses any
    #    `!ruby/object:...` tag, `!!exec`, or anything that would
    #    deserialize into a Ruby object. `aliases: false` refuses YAML
    #    aliases (billion-laughs / reference-sharing trickery). The only
    #    shapes that survive parsing are String / Integer / Float /
    #    Boolean / Array / Hash.
    #
    # 2. Registry: LegacyKeys.register runs its own `validate_spec!`
    #    allowlist — Strings, Arrays of Strings, Hashes with :default /
    #    :if_<value> / leaf-field keys. Anything else raises. Procs /
    #    Symbols / unknown hash keys cannot slip through.
    #
    # Together, the YAML parser refuses unsafe constructs at parse time
    # AND the registry refuses unexpected shapes at register time.
    # A malicious provider PR that edits a legacy.yml has no path to
    # code execution short of changing the loader or LegacyKeys source
    # itself (which is a visibly-reviewable Ruby change, not a config
    # change).
    module LegacyKeysLoader
      DEFAULT_ROOT = File.expand_path("../../..", __dir__).freeze

      class << self
        # Scan `<root>/*/workflow.yml` to locate provider directories;
        # for each, read a sibling `legacy.yml` if present and register
        # its contents under the provider-directory name as the
        # institution.
        def load_all!(root: DEFAULT_ROOT)
          Dir.glob(File.join(root, "*", "workflow.yml")).sort.each do |workflow_path|
            provider_dir = File.dirname(workflow_path)
            legacy_path  = File.join(provider_dir, "legacy.yml")
            next unless File.exist?(legacy_path)

            institution = File.basename(provider_dir)
            load_file!(legacy_path, institution: institution)
          end
        end

        # Load and register a single legacy.yml file. Extracted for
        # testability (fixtures in tmpdirs).
        def load_file!(path, institution:)
          data = parse!(path)
          validate_structure!(data, path: path)
          LegacyKeys.register(institution.to_sym, **data)
        end

        private

        def parse!(path)
          YAML.safe_load(
            File.read(path),
            permitted_classes: [],
            aliases:           false,
            symbolize_names:   true
          )
        rescue Psych::DisallowedClass, Psych::BadAlias, Psych::SyntaxError => e
          raise LegacyKeys::InvalidConfigError,
                "#{path}: unsafe or malformed YAML rejected (#{e.class}: #{e.message})"
        end

        def validate_structure!(data, path:)
          unless data.is_a?(Hash) && data.key?(:account) && data.key?(:transaction)
            raise LegacyKeys::InvalidConfigError,
                  "#{path}: expected a top-level hash with 'account' and 'transaction' keys " \
                  "(got #{data.class}; keys=#{(data.respond_to?(:keys) ? data.keys : nil).inspect})"
          end
        end
      end
    end
  end
end

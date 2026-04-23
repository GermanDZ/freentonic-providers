# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "freentonic"
require_relative "../freentonic/providers/legacy_keys_loader"

class LegacyKeysLoaderTest < Minitest::Test
  LegacyKeys       = Freentonic::Providers::LegacyKeys
  LegacyKeysLoader = Freentonic::Providers::LegacyKeysLoader

  VALID_YAML = <<~YAML
    account:
      external_id: "bank:%{source_id}"
      uids: ["bank:%{source_id}"]
      bank_key: "bank"
    transaction:
      dedup_key: "bank:%{tx_id}"
  YAML

  def setup
    LegacyKeys.__reset_for_tests!
  end

  # ---------- Auto-discovery ----------

  def test_load_all_registers_every_provider_with_workflow_and_legacy
    with_fake_providers_root do |root|
      write(root, "bank_a/workflow.yml", "version: 1")
      write(root, "bank_a/legacy.yml", VALID_YAML.gsub("bank:", "a:"))
      write(root, "bank_b/workflow.yml", "version: 1")
      write(root, "bank_b/legacy.yml", VALID_YAML.gsub("bank:", "b:"))

      LegacyKeysLoader.load_all!(root: root)

      out_a = LegacyKeys.account(institution: :bank_a, source_id: "1")
      out_b = LegacyKeys.account(institution: :bank_b, source_id: "1")
      assert_equal "a:1", out_a[:legacy_external_id]
      assert_equal "b:1", out_b[:legacy_external_id]
    end
  end

  def test_provider_without_legacy_yml_is_silently_skipped
    with_fake_providers_root do |root|
      write(root, "bank_a/workflow.yml", "version: 1")
      # no legacy.yml
      write(root, "bank_b/workflow.yml", "version: 1")
      write(root, "bank_b/legacy.yml", VALID_YAML)

      LegacyKeysLoader.load_all!(root: root)

      assert_raises(LegacyKeys::InvalidConfigError) do
        LegacyKeys.account(institution: :bank_a, source_id: "x")
      end
      # bank_b still works
      assert LegacyKeys.account(institution: :bank_b, source_id: "x")
    end
  end

  def test_stray_legacy_yml_without_workflow_yml_is_ignored
    with_fake_providers_root do |root|
      write(root, "random_dir/legacy.yml", VALID_YAML)
      # No workflow.yml next to it → should not be picked up.

      LegacyKeysLoader.load_all!(root: root)

      assert_raises(LegacyKeys::InvalidConfigError) do
        LegacyKeys.account(institution: :random_dir, source_id: "x")
      end
    end
  end

  def test_load_all_is_idempotent
    with_fake_providers_root do |root|
      write(root, "bank_a/workflow.yml", "version: 1")
      write(root, "bank_a/legacy.yml", VALID_YAML.gsub("bank:", "a:"))

      3.times { LegacyKeysLoader.load_all!(root: root) }

      out = LegacyKeys.account(institution: :bank_a, source_id: "1")
      assert_equal "a:1", out[:legacy_external_id]
    end
  end

  # ---------- Security: YAML parser hardening ----------

  def test_rejects_yaml_with_ruby_object_tag
    with_fake_providers_root do |root|
      write(root, "bank/workflow.yml", "version: 1")
      write(root, "bank/legacy.yml", <<~YAML)
        account:
          external_id: !ruby/object:String
            ivars: { "@custom": "evil" }
          uids: []
          bank_key: "x"
        transaction:
          dedup_key: "d"
      YAML

      err = assert_raises(LegacyKeys::InvalidConfigError) { LegacyKeysLoader.load_all!(root: root) }
      assert_match(/unsafe or malformed YAML/, err.message)
    end
  end

  def test_rejects_yaml_with_alias_trickery
    with_fake_providers_root do |root|
      write(root, "bank/workflow.yml", "version: 1")
      # Aliases aren't code-exec on their own but can be used for
      # billion-laughs denial-of-service. Rejecting them entirely is
      # the simplest correct policy.
      write(root, "bank/legacy.yml", <<~YAML)
        _anchor: &shared "anchor_value"
        account:
          external_id: *shared
          uids: []
          bank_key: "x"
        transaction:
          dedup_key: "d"
      YAML

      err = assert_raises(LegacyKeys::InvalidConfigError) { LegacyKeysLoader.load_all!(root: root) }
      assert_match(/unsafe or malformed YAML/, err.message)
    end
  end

  def test_rejects_malformed_yaml_syntax
    with_fake_providers_root do |root|
      write(root, "bank/workflow.yml", "version: 1")
      write(root, "bank/legacy.yml", "account: [unclosed\n")

      err = assert_raises(LegacyKeys::InvalidConfigError) { LegacyKeysLoader.load_all!(root: root) }
      assert_match(/unsafe or malformed YAML/, err.message)
    end
  end

  # ---------- Structural validation ----------

  def test_rejects_yaml_missing_account_section
    with_fake_providers_root do |root|
      write(root, "bank/workflow.yml", "version: 1")
      write(root, "bank/legacy.yml", <<~YAML)
        transaction:
          dedup_key: "d"
      YAML

      err = assert_raises(LegacyKeys::InvalidConfigError) { LegacyKeysLoader.load_all!(root: root) }
      assert_match(/'account' and 'transaction' keys/, err.message)
    end
  end

  def test_rejects_yaml_missing_transaction_section
    with_fake_providers_root do |root|
      write(root, "bank/workflow.yml", "version: 1")
      write(root, "bank/legacy.yml", <<~YAML)
        account:
          external_id: "x"
          uids: []
          bank_key: "b"
      YAML

      err = assert_raises(LegacyKeys::InvalidConfigError) { LegacyKeysLoader.load_all!(root: root) }
      assert_match(/'account' and 'transaction' keys/, err.message)
    end
  end

  def test_registry_rejects_yaml_with_forbidden_hash_key
    # Even a syntactically-valid YAML that survives safe_load should hit
    # LegacyKeys.validate_spec! at register time if it carries a
    # non-allowlisted key.
    with_fake_providers_root do |root|
      write(root, "bank/workflow.yml", "version: 1")
      write(root, "bank/legacy.yml", <<~YAML)
        account:
          external_id: "x"
          uids: []
          bank_key:
            default: "b"
            weird_key: "oops"
        transaction:
          dedup_key: "d"
      YAML

      err = assert_raises(LegacyKeys::InvalidConfigError) { LegacyKeysLoader.load_all!(root: root) }
      assert_match(/weird_key/, err.message)
    end
  end

  # ---------- Helpers ----------

  private

  def with_fake_providers_root
    Dir.mktmpdir("legacy-keys-loader-test") { |dir| yield dir }
  end

  def write(root, rel_path, content)
    full = File.join(root, rel_path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end
end

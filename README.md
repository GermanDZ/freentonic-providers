# freentonic-providers

Ready-to-use workflow YAMLs and provider plugins for the
[freentonic](https://github.com/GermanDZ/freentonic) framework.

Each subdirectory is a self-contained provider: a `workflow.yml` plus the
sibling Ruby files (`extractor.rb`, `normalizer.rb`) it references.

## Providers

| Provider  | Directory      | Status | Notes                                               |
| --------- | -------------- | ------ | --------------------------------------------------- |
| ING España | [`ing/`](ing)     | v1     | Drives the legacy `genoma_api` endpoint.            |
| Unicaja    | [`unicaja/`](unicaja) | v1     | Drives the Univia REST API. Requires `tokencsrf`.   |

## Usage

```sh
gem install freentonic
git clone https://github.com/GermanDZ/freentonic-providers

# Iterate on a normalizer without re-logging in
freentonic --workflow freentonic-providers/ing/workflow.yml \
  --through extract --dump-raw /tmp/ing_raw.json

freentonic --workflow freentonic-providers/ing/workflow.yml \
  --from-raw /tmp/ing_raw.json \
  --export json --export-path /tmp/ing_normalized.json

# Full pipeline — --export-url is the FULL endpoint URL your receiver
# listens on. Freentonic does not append a path.
freentonic --workflow freentonic-providers/ing/workflow.yml \
  --export http \
  --export-url https://receiver.example.com/v1/ingest \
  --export-token $FREENTONIC_HTTP_TOKEN
```

See the [freentonic README](https://github.com/GermanDZ/freentonic) for
workflow YAML reference, stage flags, and pluggable backends.

## Running the tests

Provider tests exercise the workflow YAMLs and their sibling
extractor/normalizer classes against stub inputs — they never touch a
real bank. The test suite depends on the `freentonic` gem, which this
repo pulls from a sibling working copy by default.

```sh
# 1. Clone freentonic next to this repo so the Gemfile path: entry resolves.
#    (If your checkout lives elsewhere, edit Gemfile or use a local override —
#    see below.)
git clone https://github.com/GermanDZ/freentonic         ../freentonic
git clone https://github.com/GermanDZ/freentonic-providers .

# 2. Install dev dependencies (minitest + rake + Ruby 3.4 default gems).
bundle install

# 3. Run everything.
bundle exec rake test

# 4. Or run one provider at a time.
bundle exec rake test:ing
bundle exec rake test:unicaja
```

If your freentonic checkout lives somewhere other than `../freentonic`,
tell Bundler where to find it without editing the Gemfile:

```sh
bundle config set --local local.freentonic /path/to/your/freentonic
bundle install
```

You can also run a single test file directly, which is useful when
iterating on a normalizer:

```sh
ruby -Iing -I../freentonic/lib ing/test/ing_normalizer_test.rb
```

## Writing a new provider

See [`docs/creating-a-provider.md`](docs/creating-a-provider.md) for a
step-by-step walkthrough: directory layout, workflow YAML skeleton,
extractor + normalizer contracts, iterative `--dump-raw` / `--from-raw`
development loop, testing, and a pre-submission checklist.

## ⚠️ Security

Workflow YAMLs and their sibling Ruby files are **code**. They drive
Chrome with your session cookies and can issue authenticated HTTP calls
against your bank. Only run files you've read. Pin this repo to a commit
hash when you clone it.

## License

MIT.

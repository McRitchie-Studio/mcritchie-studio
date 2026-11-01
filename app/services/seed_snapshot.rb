require "digest"

# Seed data too bulky for git, held in the production bucket under seed-data/.
# Every environment reads production's copy: a QA or local process does so with
# the dev token's read-only grant (docs/agents/modules/object-storage.md, Seed
# assets).
#
# read answers nil only when there is nothing to read: no R2 connection (CI, a
# keyless desk), SKIP_NETWORK_SEEDS=1 (a firewalled rebuild) or no such object. The caller skips, as seeds do for optional
# data. An R2 failure or a changed object raises, so an outage cannot pass for
# an empty snapshot and R2, which has no versioning, cannot change a seed
# unnoticed. Refreshing a snapshot means publish, then bump its pin here.
class SeedSnapshot
  class ChecksumMismatch < StandardError; end
  class ProductionOnly < StandardError; end

  PREFIX = "seed-data".freeze
  SHA256 = {
    "artists_wikidata.json" => "823a0c7d46df83c76ef29eaa1e12ab7150166abaa920eb5239a290f4a0ed14ea",
    "spotrac_contracts_2025.json" => "12c3db6d9e6adadb5ccaef3a71e66911fe9f85adb5e79b6e737a51a1b8550a45"
  }.freeze

  def self.key(name) = "#{PREFIX}/#{name}"

  def self.read(name, sha256: SHA256.fetch(name))
    return nil if ENV["SKIP_NETWORK_SEEDS"] == "1" || !StorageBackend.configured?
    return nil unless Studio::S3.production_exists?(key: key(name))

    body = Studio::S3.production_download(key: key(name))
    actual = Digest::SHA256.hexdigest(body)
    return body.force_encoding(Encoding::UTF_8) if actual == sha256

    raise ChecksumMismatch, "#{key(name)} is #{actual}, pinned #{sha256}"
  end

  # Only production writes the production bucket, so this runs on a dyno:
  # `heroku run bin/rails seed_data:publish FILE=/tmp/x.json NAME=x.json`.
  def self.publish!(path, name)
    unless Studio::S3.production_environment?
      raise ProductionOnly, "#{key(name)}: only production writes the production bucket; nothing was uploaded"
    end

    body = File.binread(path)
    Studio::S3.upload(key: key(name), body: body, content_type: "application/json")
    Digest::SHA256.hexdigest(body)
  end
end

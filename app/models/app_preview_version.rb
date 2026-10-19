# One published static bundle of a client app (docs/agents/system/client-app-host.md):
# the history behind App#preview_version. Written only by ClientApps::Publish, and
# never changed after: a version's files in storage are immutable, so its
# manifest is too.
#
#   version       "20261019T201500Z-1a2b3c4d": UTC time + random, unique per app
#   manifest      { path => { "size", "sha256", "content_type" } }, what the host
#                 serves (a path outside it is never fetched from storage)
#   published_by  the agent session's soul (and slug) that published it
class AppPreviewVersion < ApplicationRecord
  VERSION_FORMAT = /\A\d{8}T\d{6}Z-[0-9a-f]{8}\z/

  belongs_to :app, foreign_key: :app_slug, primary_key: :slug, inverse_of: :preview_versions

  validates :app_slug, presence: true
  validates :version, presence: true, format: { with: VERSION_FORMAT }, uniqueness: { scope: :app_slug }
  validates :file_count, :byte_size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :published_at, presence: true

  scope :newest_first, -> { order(published_at: :desc, id: :desc) }

  def self.mint_version(now = Time.current)
    "#{now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}"
  end

  # The storage key of PATH in this version (ClientApps::BundleStore).
  def key_for(path) = ClientApps::BundleStore.key(app_slug, version, path)

  def entry(path) = manifest.is_a?(Hash) ? manifest[path] : nil
end

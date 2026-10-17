# Moves a request's intake files into its app's folder once Build my app has
# created the app (docs/agents/system/client-cto.md; the folder rule is
# .agents/epics/chat-media-design.md, "Where files live in R2"):
#
#   intake/<request token>/<file>   →   apps/<sub>/intake/<file>
#
# For each Active Storage blob whose key starts with the request's intake
# prefix, in this order: copy the object to the new key (R2 server-side copy on
# the S3 service, a file copy on Disk, download-and-upload on anything else),
# repoint the blob's key, then delete the old object. So nothing ever points at
# a missing object: a crash before the repoint leaves the blob on its old key
# (re-run copies again), and one after it leaves only an orphaned old object
# under intake/, which the 30-day intake sweep removes.
#
# Idempotent and re-runnable: a moved blob no longer matches the prefix. Run
# after the launch commits (AppIntakeMoveJob), never inside it: an object copy
# cannot be rolled back.
class AppIntakeMove
  Result = Struct.new(:moved, :keys, keyword_init: true)

  def self.source_prefix(token) = "intake/#{token}/"
  def self.target_prefix(subdomain) = "apps/#{subdomain}/intake/"

  def initialize(request)
    @request = request
  end

  def blobs
    prefix = ActiveRecord::Base.sanitize_sql_like(self.class.source_prefix(@request.token))
    ActiveStorage::Blob.where("key LIKE ?", "#{prefix}%").order(:id)
  end

  def call
    raise ArgumentError, "request #{@request.id} has no subdomain to move into" if @request.subdomain.blank?

    keys = blobs.map { |blob| move(blob) }
    Result.new(moved: keys.size, keys: keys)
  end

  private

  def move(blob)
    old_key = blob.key
    new_key = self.class.target_prefix(@request.subdomain) + old_key.delete_prefix(self.class.source_prefix(@request.token))
    copy(blob.service, old_key, new_key, blob)
    blob.update_columns(key: new_key)
    blob.service.delete(old_key)
    new_key
  end

  def copy(service, from, to, blob)
    if service.respond_to?(:bucket) && service.bucket.respond_to?(:object)
      service.bucket.object(to).copy_from(service.bucket.object(from))
    elsif service.respond_to?(:path_for)
      target = service.path_for(to)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(service.path_for(from), target)
    else
      service.upload(to, StringIO.new(service.download(from)), checksum: blob.checksum)
    end
  end
end

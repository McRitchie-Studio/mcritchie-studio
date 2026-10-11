# frozen_string_literal: true

module Appearances
  # COPY ONE CHOSEN UNIFORM PHOTO INTO OUR STORAGE, so a sheet build never touches
  # the search hit itself (Carl's block on player-sheet-uniform-and-build).
  #
  # THE SAME PATTERN AS THE FACE PHOTOS (Appearances::MirrorCandidates::LiveCache):
  # Studio::ImageCache.fetch_response vets the host, pins the connection to the
  # address it vetted (a rebinding host cannot swap in a private one between check
  # and fetch), re-vets every redirect, and caps the size; Studio::ImageCache.cache!
  # stores the bytes. The build then sends the hosted copy, which is our own object,
  # so a hotlink 403, 404 or redirect fails HERE, at the free pick, with a reason,
  # rather than after a paid build has been claimed.
  #
  # Raises Refused with an operator-readable reason; never returns nil.
  class MirrorUniformPhoto
    PURPOSE = "uniform_photo".freeze
    KEY_ROOT = "uniform-photos".freeze

    class Refused < StandardError; end

    def self.call(photo, cache: nil) = new(photo, cache: cache).call

    def initialize(photo, cache: nil)
      @photo = photo
      @cache = cache || default_cache
    end

    # The hosted URL, written to the row. A photo already copied is not fetched again.
    def call
      return @photo.hosted_url if @photo.hosted_url.present?

      body, served = fetch
      content_type = content_type_for(served)
      check_size!(body)
      variants = Tempfile.create(["uniform", ".bin"], binmode: true) do |file|
        file.write(body)
        file.flush
        @cache.cache!(owner: @photo, purpose: PURPOSE, key_prefix: key_prefix, widths: [],
                      source_url: @photo.image_url, source_path: file.path, content_type: content_type)
      end
      url = variants["original"]&.url
      raise Refused, "the copy was stored but has no address; try again" if url.blank?

      @photo.update!(hosted_url: url)
      url
    end

    private

    def default_cache
      LiveCallTrap.refuse!(
        what: "A live image fetch and S3 upload through #{self.class}",
        remedy: "Inject a cache: Appearances::MirrorUniformPhoto.call(photo, cache: fake)."
      )
      MirrorCandidates::LiveCache
    end

    def fetch
      @cache.fetch(@photo.image_url)
    rescue Studio::ImageCache::InvalidSourceURL => e
      raise Refused, "its address was refused (#{e.message})"
    rescue Studio::ImageCache::SourceTooLarge
      raise Refused, "it is larger than we store"
    rescue StandardError => e
      raise Refused, "its host would not hand it over (#{e.message.truncate(120)})"
    end

    def content_type_for(served)
      type = served.to_s.split(";").first.to_s.strip.downcase
      return type if Studio::ImageCache::ALLOWED_CONTENT_TYPES.include?(type)

      by_extension = MirrorCandidates::CONTENT_TYPE_BY_EXTENSION[extension]
      return by_extension if by_extension && MirrorCandidates::GENERIC_CONTENT_TYPES.include?(type)

      raise Refused, "its host served #{type.presence || 'no type'}, not an image we store"
    end

    # The sheet adapter refuses a reference over this, so a copy over it is refused now.
    def check_size!(body)
      return if body.to_s.bytesize <= ImageGeneration::OpenAI::MAX_REFERENCE_BYTES

      raise Refused, "it is over #{ImageGeneration::OpenAI::MAX_REFERENCE_BYTES / 1024 / 1024} MB, too large to send"
    end

    def extension
      File.extname(URI.parse(@photo.image_url.to_s).path.to_s).delete_prefix(".").downcase
    rescue URI::InvalidURIError
      ""
    end

    def key_prefix = "#{KEY_ROOT}/#{@photo.appearance_slug}/#{@photo.slug}"
  end
end

# frozen_string_literal: true

module Characters
  # ADD ONE REFERENCE IMAGE TO A CHARACTER'S LOOK (/characters/<slug>): validate
  # the bytes, put our copy in the hub's bucket, then file it as a chosen
  # AppearanceReferencePhoto (source `upload`) the sheet build sends.
  #
  # WHY A NEW DOOR. A person's reference photographs are FOUND, never uploaded:
  # Appearances::GatherReferencePhotos searches the web and judges faces, which
  # is person-coupled by design and must never run for a fictional character.
  # So this is the brand-kit upload's rules (EmailImages::UploadReference) on
  # the look table: the type read from the BYTES (PNG, JPEG or WebP), 5 MB at
  # most, stored through Appearances::StoreGeneratedImage before the row exists
  # so a failed upload files nothing.
  #
  # CHARACTER LOOKS ONLY. A person's look is refused: an uploaded photograph of
  # a real human is exactly what the likeness rules exist to keep out.
  #
  # Returns the record: persisted on success, unsaved with errors otherwise.
  class UploadLookArt
    MAX_BYTES = EmailBrandReference::MAX_BYTES
    STORAGE_PREFIX = "characters"

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(appearance:, file:, label: nil)
      @appearance = appearance
      @file = file
      @record = AppearanceReferencePhoto.new(appearance_slug: appearance.slug,
                                             source: AppearanceReferencePhoto::SOURCE_UPLOAD,
                                             chosen: true, title: label.to_s.squish.presence)
    end

    def call
      unless @appearance.character_owned?
        @record.errors.add(:base, "Only a character's look takes uploaded art")
        return @record
      end

      bytes = read_file
      content_type = bytes.is_a?(String) ? EmailBrandReference.content_type_of(bytes) : nil
      error = file_error(bytes, content_type)
      if error
        @record.errors.add(:file, error)
        return @record
      end

      @record.mime_type = content_type
      @record.image_url = store(bytes, content_type)
      @record.save!
      @record
    rescue Appearances::StoreGeneratedImage::StoreFailed => e
      @record.errors.add(:file, "could not be stored: #{e.message}")
      @record
    end

    # Bytes in, our URL out, under characters/<character>/refs/. Public so the
    # Turf Monster seed files its kit references through the same door.
    def self.store_bytes(bytes, content_type:, character_slug:)
      data_uri = "data:#{content_type};base64,#{Base64.strict_encode64(bytes)}"
      Appearances::StoreGeneratedImage.call(data_uri, prefix: STORAGE_PREFIX, subject: "#{character_slug}/refs")
    end

    private

    def read_file
      return nil if @file.blank? || !@file.respond_to?(:read)
      return :too_big if @file.respond_to?(:size) && @file.size.to_i > MAX_BYTES

      @file.rewind if @file.respond_to?(:rewind)
      bytes = @file.read(MAX_BYTES + 1).to_s.b
      bytes.bytesize > MAX_BYTES ? :too_big : bytes
    end

    def file_error(bytes, content_type)
      return "is required" if bytes.nil? || bytes.to_s.empty?
      return "is over the #{MAX_BYTES / 1024 / 1024} MB limit" if bytes == :too_big
      return "must be a PNG, JPEG or WebP image (read from the file's content, not its name)" if content_type.nil?

      nil
    end

    def store(bytes, content_type)
      self.class.store_bytes(bytes, content_type: content_type, character_slug: @appearance.character_slug)
    end
  end
end

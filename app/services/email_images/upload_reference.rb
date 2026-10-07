# frozen_string_literal: true

module EmailImages
  # ADD ONE REFERENCE IMAGE TO A BRAND KIT: validate the file, put our copy in
  # the hub's bucket, then file the EmailBrandReference row that points at it.
  #
  # THE TYPE IS READ FROM THE BYTES. A PNG, JPEG or WebP is accepted whatever it
  # is named; a text file named logo.png is refused. Over 5 MB is refused before
  # the file is read in full.
  #
  # STORED BEFORE THE ROW EXISTS, through the same door every generated image
  # uses (Appearances::StoreGeneratedImage, prefix `email_brand`, subject
  # `<kit>/refs`), so a failed upload leaves no row pointing at nothing, and the
  # E2E lane's fake store (config/initializers/e2e_image_generation.rb) covers
  # this path too.
  #
  # Returns the record: persisted on success, unsaved with errors otherwise.
  class UploadReference
    def self.call(**kwargs) = new(**kwargs).call

    def initialize(kit:, file:, role:, label:, note: nil, by: nil)
      @kit = kit
      @file = file
      @record = EmailBrandReference.new(brand_kit: kit.to_s, role: role.to_s, label: label.to_s.squish,
                                        note: note.to_s.strip.presence, uploaded_by: by)
    end

    def call
      bytes = read_file
      content_type = bytes.is_a?(String) ? EmailBrandReference.content_type_of(bytes) : nil
      @record.content_type = content_type
      @record.byte_size = bytes.bytesize if bytes.is_a?(String)
      @record.image_url = "pending"
      @record.valid?
      @record.errors.delete(:content_type)
      @record.errors.delete(:byte_size)
      file_errors(bytes, content_type).each { |message| @record.errors.add(:file, message) }
      return @record if @record.errors.any?

      @record.width, @record.height = dimensions(bytes)
      @record.image_url = store(bytes, content_type)
      @record.save!
      @record
    rescue Appearances::StoreGeneratedImage::StoreFailed => e
      @record.image_url = nil
      @record.errors.add(:file, "could not be stored: #{e.message}")
      @record
    end

    private

    def read_file
      return nil if @file.blank? || !@file.respond_to?(:read)
      return :too_big if @file.respond_to?(:size) && @file.size.to_i > EmailBrandReference::MAX_BYTES

      @file.rewind if @file.respond_to?(:rewind)
      bytes = @file.read(EmailBrandReference::MAX_BYTES + 1).to_s.b
      bytes.bytesize > EmailBrandReference::MAX_BYTES ? :too_big : bytes
    end

    def file_errors(bytes, content_type)
      return ["is required"] if bytes.nil? || bytes.to_s.empty?
      return ["is over the #{EmailBrandReference::MAX_BYTES / 1024 / 1024} MB limit"] if bytes == :too_big
      return ["must be a PNG, JPEG or WebP image (read from the file's content, not its name)"] if content_type.nil?

      []
    end

    # Width and height for the page; a file MiniMagick cannot read still
    # uploads (its type was already proven by its bytes) with no dimensions.
    def dimensions(bytes)
      image = MiniMagick::Image.read(bytes)
      [image.width, image.height]
    rescue StandardError
      [nil, nil]
    end

    def store(bytes, content_type)
      data_uri = "data:#{content_type};base64,#{Base64.strict_encode64(bytes)}"
      Appearances::StoreGeneratedImage.call(data_uri, prefix: EmailBrandReference::STORAGE_PREFIX,
                                                      subject: EmailBrandReference.storage_subject(@kit))
    end
  end
end

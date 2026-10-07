# frozen_string_literal: true

require "fileutils"

module EmailImages
  # WRITE A BRIEF'S APPROVED HEADER TO A FILE the app will commit, and say how
  # to register it (epic email-image-builder: delivery by commit until the
  # engine learns to import from a URL in piece 4).
  #
  # The bytes come from our own bucket (the artifact's image_url), or from the
  # data URI the E2E fake stores. The answer carries the
  # Studio::EmailCatalog.register snippet and the resolver line for the app.
  class Export
    Result = Struct.new(:path, :bytesize, :snippet, keyword_init: true)

    class NotApproved < StandardError; end
    class ExportFailed < StandardError; end

    def self.call(brief, into:, **kwargs) = new(brief, into: into, **kwargs).call

    def initialize(brief, into:, image_url: nil, now: Time.current)
      @brief = brief
      @into = into.to_s
      @image_url = image_url
      @now = now
    end

    def call
      url = @image_url.presence || approved_url
      bytes = read(url)
      path = target_path
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, bytes)
      @brief.update!(exported_at: @now, exported_to: path) if @brief.persisted?
      Result.new(path: path, bytesize: bytes.bytesize, snippet: snippet)
    end

    # The code piece 2 pastes into the app, named for this brief.
    def snippet
      key = @brief.catalog_key
      <<~RUBY
        # config/initializers/studio_emails.rb
        Studio::EmailCatalog.register(
          #{key.inspect},
          label: #{key.humanize.inspect},
          description: #{"Header: #{@brief.headline}".inspect},
          default_asset: #{"emails/#{@brief.asset_filename}".inspect},
          type: :transactional
        )

        # the mailer's resolver (url + alt; alt is the headline)
        { url: Studio::EmailCatalog.resolved_url(#{key.inspect}), alt: #{@brief.effective_alt_text.inspect} }
      RUBY
    end

    private

    # A directory (or a path ending in "/") gets the brief's own file name; a
    # file path is used as given.
    def target_path
      path = File.expand_path(@into)
      return File.join(path, @brief.asset_filename) if @into.end_with?("/") || File.directory?(path)

      path
    end

    def approved_url
      artifact = @brief.approved_artifact
      raise NotApproved, "#{@brief.slug} has no approved header yet; approve one on /email_images/#{@brief.slug}" unless artifact&.approved?

      artifact.image_url
    end

    def read(url)
      EmailImages::Download.bytes(url)
    rescue EmailImages::Download::Failed => e
      raise ExportFailed, e.message
    end
  end
end

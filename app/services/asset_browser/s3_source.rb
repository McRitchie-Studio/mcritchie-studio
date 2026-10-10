# frozen_string_literal: true

# AssetBrowser's live source: Studio::S3's own client and bucket (Cloudflare R2). Keys go in and come out
# LOGICAL, through Studio::S3's key namespace.
module AssetBrowser
  class S3Source
    def initialize(client: nil, bucket: nil)
      @client = client
      @bucket = bucket
    end

    def label
      "#{StorageBackend.studio_s3_stage} · #{bucket}"
    end

    def list(prefix:, max:, delimiter:, token: nil)
      params = { bucket: bucket, prefix: Studio::S3.full_key(prefix.to_s), delimiter: delimiter,
                 max_keys: max, continuation_token: token }.compact
      resp = storage { client.list_objects_v2(**params) }
      Page.new(
        folders: resp.common_prefixes.map { |p| Studio::S3.logical_key(p.prefix) },
        files: resp.contents.reject { |o| o.key.end_with?("/") }.map do |o|
          Entry.new(key: Studio::S3.logical_key(o.key), size: o.size, last_modified: o.last_modified)
        end,
        next_token: resp.is_truncated ? resp.next_continuation_token : nil
      )
    end

    def head(key:)
      resp = storage { client.head_object(bucket: bucket, key: Studio::S3.full_key(key)) }
      Entry.new(key: key, size: resp.content_length, last_modified: resp.last_modified, content_type: resp.content_type)
    rescue Unavailable => e
      raise unless e.message.start_with?("NotFound", "NoSuchKey")

      nil
    end

    # Inside `storage` so aws-sdk-s3 is loaded even when no list or head ran first.
    # download_as: a file name makes the URL answer as an attachment, so a link
    # to it saves the file instead of playing it in the tab.
    def signed_url(key:, expires_in:, download_as: nil)
      params = { bucket: bucket, key: Studio::S3.full_key(key), expires_in: expires_in }
      params[:response_content_disposition] = ActionDispatch::Http::ContentDisposition.format(disposition: "attachment", filename: download_as) if download_as
      storage { Aws::S3::Presigner.new(client: client).presigned_url(:get_object, **params) }
    end

    private

    # A process with no R2 connection (CI, a keyless desk) holds placeholder
    # keys, which would sign a URL nobody can fetch. That reads as Unavailable.
    def client
      @client ||= storage do
        raise Studio::S3::NotConfigured, "no R2 connection" unless StorageBackend.configured?

        Studio::S3.client
      end
    end

    def bucket
      @bucket ||= storage { Studio::S3.bucket }
    end

    # The class name only: an SDK message can carry a bucket or key detail, never a credential,
    # but the page has no use for more than what failed.
    def storage
      require "aws-sdk-s3"
      yield
    rescue Studio::S3::NotConfigured
      raise Unavailable, "Object storage is not configured for this app"
    rescue Aws::Errors::ServiceError, Aws::Errors::MissingCredentialsError, Aws::Sigv4::Errors::MissingCredentialsError,
           Seahorse::Client::NetworkingError => e
      raise Unavailable, e.class.name.demodulize
    end
  end
end

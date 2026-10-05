module MusicVideos
  # The hub's object store as MusicVideos::Stitcher reads and writes it: whole
  # files, streamed to and from disk, never held in memory. bin/stitch-video
  # hands the stitcher DigestVideo::R2Storage instead; same two methods.
  class StitchStorage
    def get(key, path)
      require "aws-sdk-s3"
      Studio::S3.client.get_object(bucket: Studio::S3.bucket, key: Studio::S3.full_key(key), response_target: path)
      path
    rescue Studio::S3::NotConfigured
      raise Stitcher::Failure, "object storage is not configured for this app"
    rescue Aws::Errors::ServiceError, Aws::Errors::MissingCredentialsError, Seahorse::Client::NetworkingError => e
      raise Stitcher::Failure, "object storage did not serve #{key} (#{e.class.name.demodulize})"
    end

    def put(key, path, content_type)
      require "aws-sdk-s3"
      File.open(path, "rb") { |io| Studio::S3.upload(key:, body: io, content_type:) }
    rescue Studio::S3::NotConfigured
      raise Stitcher::Failure, "object storage is not configured for this app"
    rescue Aws::Errors::ServiceError, Aws::Errors::MissingCredentialsError, Seahorse::Client::NetworkingError => e
      raise Stitcher::Failure, "object storage did not take #{key} (#{e.class.name.demodulize})"
    end
  end
end

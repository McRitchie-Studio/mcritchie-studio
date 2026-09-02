# frozen_string_literal: true

# The desk@mcritchie.studio capture pipe's S3 side. Deliberately NOT
# Studio::S3: that facade owns the app's public asset bucket pair
# (mcritchie-studio-{dev,production}, world-readable by policy), and raw
# forwarded mail with deal attachments must never land there. The desk bucket
# is its own PRIVATE bucket in us-east-1 (SES inbound's region), reachable with
# the app's existing AWS credentials.
module DeskCapture
  INCOMING_PREFIX = "incoming/"
  PARSED_PREFIX   = "parsed/"

  class << self
    def bucket
      ENV.fetch("DESK_CAPTURE_BUCKET", "mcritchie-studio-desk")
    end

    def region
      ENV.fetch("DESK_CAPTURE_REGION", "us-east-1")
    end

    # Whether this environment can touch the capture bucket at all. Local desks
    # without AWS credentials skip polling rather than erroring every 5 minutes;
    # production misconfiguration still fails loudly inside the job.
    def configured?
      ENV["AWS_ACCESS_KEY_ID"].present?
    end

    def client
      @client ||= begin
        require "aws-sdk-s3"
        Aws::S3::Client.new(region: region)
      end
    end

    def reset!
      @client = nil
    end

    def list_incoming_keys(max: 200)
      client.list_objects_v2(bucket: bucket, prefix: INCOMING_PREFIX, max_keys: max)
            .contents.map(&:key)
            .reject { |k| k.end_with?("/") || k.end_with?("AMAZON_SES_SETUP_NOTIFICATION") }
    end

    def read(key)
      client.get_object(bucket: bucket, key: key).body.read
    end

    def store(key, body, content_type: nil)
      opts = { bucket: bucket, key: key, body: body }
      opts[:content_type] = content_type if content_type
      client.put_object(**opts)
      key
    end
  end
end

# frozen_string_literal: true

require "test_helper"

# [unit] StoreGeneratedImage's folder is generalised: a character sheet still
# lands under character-sheets/<person>/, an email header under the prefix and
# subject its caller names. S3 is stubbed; nothing is uploaded.
class Appearances::StoreGeneratedImagePrefixTest < ActiveSupport::TestCase
  DATA = "data:image/jpeg;base64,#{Base64.strict_encode64('JPGBYTES')}".freeze

  def keys_for(**kwargs)
    keys = []
    Studio::S3.stub(:upload, ->(key:, **) { keys << key }) do
      Studio::S3.stub(:url, ->(key:) { "https://assets.example.test/#{key}" }) do
        Appearances::StoreGeneratedImage.call(DATA, **kwargs)
      end
    end
    keys
  end

  test "the default folder is unchanged for a person" do
    assert_match %r{\Acharacter-sheets/josh-allen/\d{14}-\h{8}\.jpg\z}, keys_for(person_slug: "josh-allen").sole
  end

  test "an email header lands under email_images/<app>/<email_key>/<variant>" do
    key = keys_for(prefix: "email_images", subject: "turf-monster/drop_signup_confirmation/new_player").sole
    assert_match %r{\Aemail_images/turf-monster/drop_signup_confirmation/new_player/\d{14}-\h{8}\.jpg\z}, key
  end
end

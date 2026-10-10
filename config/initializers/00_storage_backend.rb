# frozen_string_literal: true

# THE HUB'S OBJECT STORAGE IS CLOUDFLARE R2, AND ONLY R2. AWS was retired on
# 2026-10-10 (IAM users, keys and buckets gone), so there is no S3 stage and no
# mirror stage left to select: the move's history is
# docs/agents/system/r2-cutover-record.md.
#
#   ACTIVE_STORAGE_BACKEND  unset or `r2`
#     Read by config/storage.yml for BOTH durable services, `amazon` (production,
#     QA) and `amazon_dev` (local desks). The names are kept because blob rows
#     record them; both resolve to R2.
#
#   STUDIO_S3_BACKEND       unset or `r2`
#     Read by config/initializers/studio.rb for Studio::S3.
#
# Both variables are optional and exist so the live config (`r2` on every app)
# stays valid. Unset means R2. A RETIRED value (s3, mirror_to_r2, mirror_to_s3)
# or a typo RAISES at boot in every environment: it must never look like a
# successful selection of a store that no longer exists.
#
# R2 connection: R2_ENDPOINT, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY (1Password
# r2.mcritchie-studio: the prod pair on production, the dev pair on QA and
# locally) and R2_PUBLIC_URL (https://assets.mcritchie.studio), because the hub
# hands out PUBLIC Studio::S3 URLs (ImageCache, broadcasts, lineups).
#
# A MISSING R2 VARIABLE:
#   production (and QA, which boots RAILS_ENV=production)  RAISES at boot, naming
#     the variable. A dyno that boots without storage fails at the first upload,
#     hours later; one that refuses to boot fails the deploy.
#   test, CI, a keyless local desk  boots. The service is still R2-shaped, built
#     on UNCONFIGURED: a reserved `.invalid` host (RFC 2606, never resolves) and
#     placeholder keys. Nothing can reach AWS or any real bucket, and the first
#     real call fails naming r2-not-configured.invalid.
module StorageBackend
  STAGE = "r2"
  RETIRED_STAGES = %w[s3 mirror_to_r2 mirror_to_s3].freeze

  # The engine's Active Storage service: S3Service whose delete MOVES the object
  # under trash/<utc date>/<epoch ms>/<key> (copy first, then delete), so a
  # purged or replaced attachment has a three-day grace period. The bucket's
  # `expire-trash-3d` lifecycle rule removes it after that. Restore with
  # `rake studio:trash:restore[TRASH_KEY]`.
  ACTIVE_STORAGE_SERVICE = "StudioTrashS3"

  UNCONFIGURED_HOST = "r2-not-configured.invalid"
  UNCONFIGURED = {
    "R2_ENDPOINT" => "https://#{UNCONFIGURED_HOST}",
    "R2_ACCESS_KEY_ID" => "r2-not-configured",
    "R2_SECRET_ACCESS_KEY" => "r2-not-configured",
    "R2_PUBLIC_URL" => "https://#{UNCONFIGURED_HOST}"
  }.freeze

  module_function

  # Whether a missing R2 variable refuses the boot. Production and QA both run
  # RAILS_ENV=production.
  def strict?
    Rails.env.production?
  end

  def active_storage_stage(env = ENV)
    stage(env, "ACTIVE_STORAGE_BACKEND")
  end

  def studio_s3_stage(env = ENV)
    stage(env, "STUDIO_S3_BACKEND")
  end

  # Whether this process holds a real R2 connection: every R2_* variable set.
  # Always true in production and QA (boot raised otherwise). False on CI and a
  # keyless desk, where the services are built on UNCONFIGURED; code that must
  # refuse up front rather than fail at its first call asks this, because the
  # placeholder keys make "is a key set?" answer yes.
  def configured?(env = ENV)
    UNCONFIGURED.each_key.all? { |name| !env[name].to_s.strip.empty? }
  end

  # The credentials an operator should check when Studio::S3 (headshots,
  # broadcasts, reference photos) fails wholesale.
  def credential_hint(_env = ENV)
    "R2_ENDPOINT / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_PUBLIC_URL " \
      "(local dev reads them from .env.development)"
  end

  # The Studio.configure settings: the R2 connection and public URL, always.
  def studio_s3_settings(env = ENV, strict: strict?)
    studio_s3_stage(env)
    {
      s3_endpoint: r2_value(env, "R2_ENDPOINT", strict: strict),
      s3_region: "auto",
      s3_access_key_id: r2_value(env, "R2_ACCESS_KEY_ID", strict: strict),
      s3_secret_access_key: r2_value(env, "R2_SECRET_ACCESS_KEY", strict: strict),
      s3_public_url: r2_value(env, "R2_PUBLIC_URL", strict: strict)
    }
  end

  # The Active Storage services config/storage.yml renders, for { name => bucket }.
  def active_storage_services(buckets, env = ENV, strict: strict?)
    active_storage_stage(env)
    buckets.transform_values { |bucket| r2_service(bucket, env, strict: strict) }
  end

  # Checksums only when required: Active Storage sends Content-MD5, aws-sdk-s3
  # >= 1.178 adds a CRC32, and R2 refuses both at once (measured 2026-09-28).
  def r2_service(bucket, env = ENV, strict: strict?)
    { "service" => ACTIVE_STORAGE_SERVICE,
      "endpoint" => r2_value(env, "R2_ENDPOINT", strict: strict),
      "access_key_id" => r2_value(env, "R2_ACCESS_KEY_ID", strict: strict),
      "secret_access_key" => r2_value(env, "R2_SECRET_ACCESS_KEY", strict: strict),
      "region" => "auto", "bucket" => bucket,
      "request_checksum_calculation" => "when_required",
      "response_checksum_validation" => "when_required" }
  end

  # Everything a boot needs, checked in one place and called at the foot of this
  # file. config/storage.yml is rendered lazily (a rake task such as the release
  # phase's db:migrate never renders it), so without this a bad value passed the
  # release and then crash-looped web and worker (measured on Turf, 2026-09-30).
  # Raising from an initializer fails the release phase instead.
  def validate!(env = ENV, strict: strict?)
    active_storage_stage(env)
    studio_s3_stage(env)
    UNCONFIGURED.each_key { |name| r2_value(env, name, strict: strict) }
    true
  end

  def stage(env, name)
    value = env[name].to_s.strip
    return STAGE if value.empty? || value == STAGE

    if RETIRED_STAGES.include?(value)
      raise ArgumentError, "#{name}=#{value.inspect} names a retired stage: AWS S3 was retired on " \
                           "2026-10-10 and the hub's storage runs on Cloudflare R2 only. " \
                           "Unset #{name} or set it to #{STAGE}."
    end

    raise ArgumentError, "#{name}=#{value.inspect} is not a storage backend; unset it or set it to #{STAGE}"
  end

  def r2_value(env, name, strict:)
    value = env[name].to_s.strip
    return value unless value.empty?
    return UNCONFIGURED.fetch(name) unless strict

    raise ArgumentError, "#{name} must be set: the hub's storage runs on Cloudflare R2 only, and " \
                         "production and QA refuse to boot without it (1Password r2.mcritchie-studio)"
  end
end

StorageBackend.validate!

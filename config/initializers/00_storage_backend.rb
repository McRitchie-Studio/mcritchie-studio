# frozen_string_literal: true

# THE MOVE OFF AWS S3 ONTO CLOUDFLARE R2 (asset-library Wave 2; recipe in
# docs/agents/system/asset-library-plan.md). The same two switches
# mcritchie-industries shipped, both inert until set, so every step of the move
# is a config change rather than a deploy:
#
#   ACTIVE_STORAGE_BACKEND  s3 (default) → mirror_to_r2 → mirror_to_s3 → r2
#     Read by config/storage.yml for BOTH durable services, `amazon` (production,
#     QA) and `amazon_dev` (local desks). Each keeps its NAME at every stage,
#     since blob rows record it; only what it resolves to changes. The mirror
#     stages write both stores, so this half of the move is reversible by config.
#
#   STUDIO_S3_BACKEND       s3 (default) | r2
#     Read by config/initializers/studio.rb. Studio::S3 has no mirror, so it
#     moves in ONE step, then a catch-up copy.
#
# R2 connection: R2_ENDPOINT, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY (1Password
# r2.mcritchie-studio: the prod pair on production, the dev pair locally). Bucket
# names match on both stores.
#
# Unlike industries, the hub hands out PUBLIC Studio::S3 URLs (ImageCache,
# broadcasts, lineups), so STUDIO_S3_BACKEND=r2 also requires R2_PUBLIC_URL
# (https://assets.mcritchie.studio): Studio::S3.url raises on R2 without one.
#
# An unknown value RAISES at boot: a typo must not look like a successful flip.
module StorageBackend
  ACTIVE_STORAGE_STAGES = %w[s3 mirror_to_r2 mirror_to_s3 r2].freeze
  STUDIO_S3_STAGES = %w[s3 r2].freeze

  module_function

  def active_storage_stage(env = ENV)
    stage(env, "ACTIVE_STORAGE_BACKEND", ACTIVE_STORAGE_STAGES)
  end

  def studio_s3_stage(env = ENV)
    stage(env, "STUDIO_S3_BACKEND", STUDIO_S3_STAGES)
  end

  # The credentials an operator should check when Studio::S3 (headshots, broadcasts,
  # reference photos) fails wholesale: the R2 keys once STUDIO_S3_BACKEND=r2
  # (production, QA and local dev since 2026-09-30), else the AWS keys. Remedy text
  # that always named AWS sent operators to keys the R2 path never reads.
  def credential_hint(env = ENV)
    if studio_s3_stage(env) == "r2"
      "R2_ENDPOINT / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY (STUDIO_S3_BACKEND=r2; " \
        "local dev reads them from .env.development)"
    else
      "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION in .env"
    end
  end

  # The Studio.configure settings for the current stage: {} on S3 (the engine's
  # AWS defaults, exactly as before), the R2 connection and public URL on r2.
  def studio_s3_settings(env = ENV)
    return {} if studio_s3_stage(env) == "s3"

    {
      s3_endpoint: require!(env, "R2_ENDPOINT"),
      s3_region: "auto",
      s3_access_key_id: require!(env, "R2_ACCESS_KEY_ID"),
      s3_secret_access_key: require!(env, "R2_SECRET_ACCESS_KEY"),
      s3_public_url: require!(env, "R2_PUBLIC_URL")
    }
  end

  # The Active Storage services config/storage.yml renders, for { name => bucket }.
  # The s3 stage returns exactly the pre-R2 services; other stages add
  # <name>_s3 and <name>_r2 and point <name> at a Mirror or at R2.
  def active_storage_services(buckets, env = ENV)
    stage = active_storage_stage(env)
    buckets.each_with_object({}) do |(name, bucket), services|
      s3 = s3_service(bucket, env)
      if stage == "s3"
        services[name] = s3
        next
      end

      r2 = r2_service(bucket, env)
      services["#{name}_s3"] = s3
      services["#{name}_r2"] = r2
      services[name] =
        case stage
        when "r2" then r2
        when "mirror_to_r2" then { "service" => "Mirror", "primary" => "#{name}_s3", "mirrors" => [ "#{name}_r2" ] }
        else { "service" => "Mirror", "primary" => "#{name}_r2", "mirrors" => [ "#{name}_s3" ] }
        end
    end
  end

  # Blank keys read as nil, as the old unquoted YAML rendered them.
  def s3_service(bucket, env = ENV)
    { "service" => "S3", "access_key_id" => env["AWS_ACCESS_KEY_ID"].to_s.strip.presence,
      "secret_access_key" => env["AWS_SECRET_ACCESS_KEY"].to_s.strip.presence,
      "region" => "us-east-2", "bucket" => bucket }
  end

  # Checksums only when required: Active Storage sends Content-MD5, aws-sdk-s3
  # >= 1.178 adds a CRC32, and R2 refuses both at once (measured 2026-09-28).
  def r2_service(bucket, env = ENV)
    { "service" => "S3", "endpoint" => require!(env, "R2_ENDPOINT"),
      "access_key_id" => require!(env, "R2_ACCESS_KEY_ID"),
      "secret_access_key" => require!(env, "R2_SECRET_ACCESS_KEY"),
      "region" => "auto", "bucket" => bucket,
      "request_checksum_calculation" => "when_required",
      "response_checksum_validation" => "when_required" }
  end

  def stage(env, name, allowed)
    value = env[name].to_s.strip
    return allowed.first if value.empty?
    return value if allowed.include?(value)

    raise ArgumentError, "#{name}=#{value.inspect} is not one of #{allowed.join(', ')}"
  end

  def require!(env, name)
    value = env[name].to_s.strip
    raise ArgumentError, "#{name} must be set when a storage backend is r2" if value.empty?

    value
  end
end

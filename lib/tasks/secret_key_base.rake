# Read-only proof for a SECRET_KEY_BASE swap (docs/agents/system/secrets-rotation.md,
# "Hub SECRET_KEY_BASE"). Prints digests and PASS/FAIL, never a key; exits 1 on FAIL.
namespace :secret_key_base do
  desc "Prove a cookie written under OLD_SECRET_KEY_BASE reads under the live key"
  task verify_rotation: :environment do
    ok, lines = SecretKeyBaseRotation.verify
    puts lines
    exit(1) unless ok
  end
end

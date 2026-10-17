# Sample files for the CTO web chat's attachments (AgentMessages::Attachments):
# real bytes from test/fixtures/files/chat, plus the smallest headers Marcel
# reads as WebP, GIF and SVG. `upload_sample` stores one the way the composer's
# upload does, so the blob sits under the user's and app's key prefix.
module ChatAttachmentSamples
  DIR = Rails.root.join("test/fixtures/files/chat")

  BYTES = {
    "png" => -> { File.binread(DIR.join("probe.png")) },
    "jpg" => -> { File.binread(DIR.join("gps.jpg")) },
    "pdf" => -> { File.binread(DIR.join("probe.pdf")) },
    "heic" => -> { File.binread(DIR.join("sample.heic")) },
    "webp" => -> { "RIFF\x24\x00\x00\x00WEBPVP8 \x18\x00\x00\x00".b + ("\x00".b * 24) },
    "gif" => -> { "GIF89a\x01\x00\x01\x00\x00\x00\x00;".b },
    "svg" => -> { %(<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>) }
  }.freeze

  def sample_bytes(ext) = BYTES.fetch(ext).call

  def upload_sample(user, ext, app: "turf-monster", name: nil)
    AgentMessages::Attachments.upload!(io: StringIO.new(sample_bytes(ext)), filename: name || "sample.#{ext}",
                                       app_slug: app, user: user)
  end

  def sample_token(user, ext, **opts) = AgentMessages::Attachments.token_for(upload_sample(user, ext, **opts))
end

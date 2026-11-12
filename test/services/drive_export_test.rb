require "test_helper"
require "support/google_connect_fakes"
require "support/drive_filer_fake"

# [integration] DriveExport, the dyno half of `bin/drive` (/tasks/drive-filing):
# the request a CLI run sends, through DriveFiler, to a fake Drive and the
# DriveFiling log. Dry first, then applied; refusals come back as errors and
# the answer never carries the bytes or a token. Every name and byte is invented.
class DriveExportTest < ActiveSupport::TestCase
  include GoogleConnectFakes

  BYTES = "%PDF-1.4 invented fixture\n".b.freeze
  TOKEN = "ya29.synthetic-export-token".freeze

  setup do
    @drive = DriveFilerFake.new
    GoogleConnect::DriveFiler.http = @drive
  end

  teardown { GoogleConnect::DriveFiler.http = nil }

  def oauth = Struct.new(:token) { def access_token(_) = token }.new(TOKEN)

  def connect(email = "owner@example.com", scope: DRIVE, abilities: %i[drive])
    store_google(email:, scope: "openid email #{scope}", abilities:, user: users(:alex))
  end

  def drive(verb, **over)
    DriveExport.call({ "verb" => verb, "mailbox" => "owner@example.com", "by" => "pokemon" }.merge(over.transform_keys(&:to_s)), oauth:)
  end

  def upload(**over)
    drive("upload", name: "sample-policy.pdf", folder: "Records/Policies", content_base64: Base64.strict_encode64(BYTES),
                    md5: Digest::MD5.hexdigest(BYTES), **over)
  end

  test "[integration] upload runs dry, then files, then skips the same bytes, logging each" do
    connect

    dry = upload
    assert_equal [ false, nil ], dry["filed"].values_at("applied", "drive_file_id")
    assert_empty @drive.writes

    filed = upload(apply: true)
    assert filed["filed"]["drive_file_id"].present?

    again = upload(apply: true, name: "renamed.pdf")
    assert again["filed"]["duplicate"]
    assert_equal filed["filed"]["drive_file_id"], again["filed"]["drive_file_id"]
    assert_equal 1, @drive.uploads.size
    assert_equal [ [ false, false ], [ true, false ], [ true, true ] ], DriveFiling.order(:id).pluck(:applied, :duplicate)

    answer = [ dry, filed, again ].to_json
    assert_not_includes answer, TOKEN
    assert_not_includes answer, Base64.strict_encode64(BYTES)
  end

  test "[integration] mkdir and ls go through the same connection" do
    connect
    assert_equal [ "Records/Policies" ], drive("mkdir", folder: "Records/Policies")["folder"]["would_create"].last(1)
    drive("mkdir", folder: "Records/Policies", apply: true)
    assert_equal [ "Policies" ], drive("ls", folder: "Records")["files"].map { _1["name"] }
  end

  test "[integration] an account without Drive, or not connected, answers an error and writes nothing" do
    connect(scope: GMAIL, abilities: %i[gmail])
    assert_match(/has not connected Google Drive/, upload(apply: true)["error"])
    assert_match(/is not connected/, upload(mailbox: "nobody@example.com", apply: true)["error"])
    assert_match(/unknown verb/, drive("delete")["error"])
    assert_empty @drive.calls
  end

  test "[integration] bytes that arrive changed are refused" do
    connect
    assert_match(/md5 mismatch/, upload(apply: true, md5: "0" * 32)["error"])
    assert_match(/invalid base64/, upload(apply: true, content_base64: "not base64!")["error"])
    assert_empty @drive.calls
  end

  test "[integration] an unexpected fault lands in ErrorLog and answers an error" do
    connect
    @drive.define_singleton_method(:call) { |*| [ 200, "not json", {} ] }

    assert_difference -> { ErrorLog.count }, 1 do
      answer = drive("mkdir", folder: "Records", apply: true)
      assert_match(/\AJSON::ParserError/, answer["error"])
      refute_includes answer.to_json, TOKEN
    end
    refute_includes ErrorLog.last.message.to_s, TOKEN
  end
end

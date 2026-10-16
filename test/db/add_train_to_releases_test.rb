# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261016220000_add_train_to_releases.rb")

# The release-train migration runs both ways on a table that already holds rows:
# `up` stamps every existing release "hub" and scopes the active index by train;
# `down` restores the global (1) index, and refuses over two active trains.
class AddTrainToReleasesTest < ActiveSupport::TestCase
  INDEX = "index_releases_single_active"

  setup do
    @connection = ActiveRecord::Base.connection
    @migration = AddTrainToReleases.new.tap { |migration| migration.verbose = false }
  end

  teardown { Release.reset_column_information }

  def active_index = @connection.indexes("releases").find { |index| index.name == INDEX }

  test "[integration] down restores the global index; up stamps existing rows hub and scopes the index by train" do
    shipped = Release.open!.tap { |release| release.update!(state: "shipped") }
    active  = Release.open!

    @migration.down
    Release.reset_column_information

    assert_not_includes @connection.columns("releases").map(&:name), "train"
    assert_equal "(1)", active_index.columns
    assert_raises(ActiveRecord::RecordNotUnique) do
      Release.transaction(requires_new: true) do
        @connection.execute("INSERT INTO releases (slug, branch, state, created_at, updated_at) " \
                            "VALUES ('rel-down-probe', 'release', 'assembling', now(), now())")
      end
    end

    @migration.up
    Release.reset_column_information

    assert_equal %w[hub hub], [ shipped, active ].map { |release| release.reload.train }
    column = @connection.columns("releases").find { |candidate| candidate.name == "train" }
    assert_equal "hub", column.default
    assert_not column.null
    assert_equal [ "train" ], active_index.columns
    assert active_index.unique
    assert Release.open!(train: "turf-monster").persisted?, "a second train coexists after up"
  end

  test "[integration] down refuses, changing nothing, while two trains are active" do
    Release.open!
    Release.open!(train: "turf-monster")

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      Release.transaction(requires_new: true) { @migration.down }
    end
    assert_match(/2 active releases/, error.message)
    assert_includes @connection.columns("releases").map(&:name), "train"
    assert_equal [ "train" ], active_index.columns
  end
end

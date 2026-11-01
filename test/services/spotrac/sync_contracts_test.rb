require "test_helper"
require "minitest/mock"

class Spotrac::SyncContractsTest < ActiveSupport::TestCase
  setup do
    @bills = teams(:buffalo_bills)
    @dolphins = teams(:miami_dolphins)
  end

  def entry(overrides = {})
    {
      first_name: "Test", last_name: "Salary",
      position: "QB", team_code: "buf", team_slug: @bills.slug,
      start_year: 2025, end_year: 2028, years: 4,
      total_value_cents: 20_000_000_000,
      annual_value_cents: 5_000_000_000,
      guaranteed_cents:   8_000_000_000
    }.merge(overrides)
  end

  def snapshot_rows = [entry(first_name: "Snapshot", last_name: "Row")].to_json

  test "by default it reads the snapshot from R2" do
    read = ->(name) { name == "spotrac_contracts_2025.json" ? snapshot_rows : flunk(name) }
    SeedSnapshot.stub(:read, read) do
      assert_difference -> { Contract.count }, 1 do
        assert_output(/Spotrac sync: 1 entries/) { Spotrac::SyncContracts.new.call }
      end
    end
  end

  test "skips and changes nothing when the R2 snapshot is absent" do
    SeedSnapshot.stub(:read, nil) do
      assert_no_difference -> { [Contract.count, Athlete.count] } do
        assert_output(/seed-data\/spotrac_contracts_2025.json.*skipping/) do
          assert_empty Spotrac::SyncContracts.new.call
        end
      end
    end
  end

  test "an R2 failure stops the sync instead of reading as absent" do
    SeedSnapshot.stub(:read, ->(_name) { raise Studio::S3::Error, "403" }) do
      assert_raises(Studio::S3::Error) { Spotrac::SyncContracts.new.call }
    end
  end

  test "an explicit json_path reads that file and never asks R2" do
    Tempfile.create(["contracts", ".json"]) do |file|
      file.write(snapshot_rows)
      file.flush
      SeedSnapshot.stub(:read, ->(_name) { flunk "asked R2" }) do
        assert_output(/Spotrac sync: 1 entries/) { Spotrac::SyncContracts.new(json_path: file.path).call }
      end
    end
  end

  test "matches existing Athlete by otc_id when present" do
    person = Person.create!(first_name: "Tester", last_name: "Salary", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football",
                               position: "QB", otc_id: "12345")

    service = Spotrac::SyncContracts.new(entries: [entry(otc_id: "12345")])
    service.call

    contract = Contract.find_by(person_slug: person.slug, team_slug: @bills.slug)
    assert contract, "Contract should be created on the matched athlete"
    assert_equal 5_000_000_000, contract.annual_value_cents
    assert_equal Date.new(2028, 3, 15), contract.expires_at
    assert_equal "QB", contract.position
    assert_equal 1, service.stats[:contracts_created]
  end

  test "falls back to name match when otc_id absent" do
    person = Person.create!(first_name: "Test", last_name: "Salary", athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", position: "QB")

    service = Spotrac::SyncContracts.new(entries: [entry])
    service.call

    contract = Contract.find_by(person_slug: person.slug, team_slug: @bills.slug)
    assert contract
    assert_equal 5_000_000_000, contract.annual_value_cents
  end

  test "creates Person + Athlete when neither otc_id nor name resolve" do
    service = Spotrac::SyncContracts.new(entries: [entry(first_name: "Brand", last_name: "New")])
    service.call

    person = Person.find_by(slug: "brand-new")
    assert person
    assert person.athlete_profile
    assert_equal 1, service.stats[:athletes_created]
  end

  test "updates salary on existing Contract" do
    person = Person.create!(first_name: "Existing", last_name: "Contract", athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", position: "QB")
    Contract.create!(person_slug: person.slug, team_slug: @bills.slug,
                     contract_type: "active", position: "QB",
                     annual_value_cents: 1_000_000_000, expires_at: Date.new(2025, 3, 15))

    data = entry(first_name: "Existing", last_name: "Contract",
                 annual_value_cents: 9_000_000_000, end_year: 2030)
    service = Spotrac::SyncContracts.new(entries: [data])
    service.call

    contract = Contract.find_by(person_slug: person.slug, team_slug: @bills.slug)
    assert_equal 9_000_000_000, contract.annual_value_cents
    assert_equal Date.new(2030, 3, 15), contract.expires_at
    assert_equal 1, service.stats[:contracts_updated]
  end

  test "no-op when Contract already matches Spotrac data" do
    person = Person.create!(first_name: "Stable", last_name: "Pay", athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football", position: "QB", team_slug: @bills.slug)
    Contract.create!(person_slug: person.slug, team_slug: @bills.slug,
                     contract_type: "active", position: "QB",
                     annual_value_cents: 5_000_000_000, expires_at: Date.new(2028, 3, 15))

    service = Spotrac::SyncContracts.new(entries: [entry(first_name: "Stable", last_name: "Pay")])
    service.call

    assert_equal 1, service.stats[:contracts_unchanged]
    assert_equal 0, service.stats[:contracts_updated]
  end

  test "syncs Athlete.team_slug from Spotrac team" do
    person = Person.create!(first_name: "Move", last_name: "Team", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football",
                               position: "QB", team_slug: @dolphins.slug)

    service = Spotrac::SyncContracts.new(entries: [entry(first_name: "Move", last_name: "Team")])
    service.call

    assert_equal @bills.slug, athlete.reload.team_slug
    assert_equal 1, service.stats[:team_slug_updates]
  end

  test "backfills otc_id on existing Athlete when Spotrac entry has it" do
    person = Person.create!(first_name: "Backfill", last_name: "Otc", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", position: "QB")

    service = Spotrac::SyncContracts.new(entries: [entry(first_name: "Backfill", last_name: "Otc",
                                                          otc_id: "55555")])
    service.call

    assert_equal "55555", athlete.reload.otc_id
    assert_equal 1, service.stats[:otc_ids_backfilled]
  end

  test "normalizes Spotrac position via :spotrac source map" do
    service = Spotrac::SyncContracts.new(entries: [entry(first_name: "Pos", last_name: "Norm", position: "T")])
    service.call

    person = Person.find_by(slug: "pos-norm")
    assert_equal "OT", person.athlete_profile.position
    contract = Contract.find_by(person_slug: person.slug, team_slug: @bills.slug)
    assert_equal "OT", contract.position
  end
end

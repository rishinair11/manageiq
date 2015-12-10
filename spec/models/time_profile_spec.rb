require "spec_helper"

describe TimeProfile do
  before(:each) do
    @server = EvmSpecHelper.local_miq_server
    @ems    = FactoryGirl.create(:ems_vmware, :zone => @server.zone)
    EvmSpecHelper.clear_caches
  end

  it "will default to the correct profile values" do
    t = TimeProfile.new
    t.days.should == TimeProfile::ALL_DAYS
    t.hours.should == TimeProfile::ALL_HOURS
    t.tz.should    be_nil
  end

  context "will seed the database" do
    before(:each) do
      TimeProfile.seed
    end

    it do
      t = TimeProfile.first
      t.days.should == TimeProfile::ALL_DAYS
      t.hours.should == TimeProfile::ALL_HOURS
      t.tz.should == TimeProfile::DEFAULT_TZ
      t.entire_tz?.should be_true
    end

    it "but not reseed when called twice" do
      TimeProfile.seed
      TimeProfile.count.should == 1
      t = TimeProfile.first
      t.days.should == TimeProfile::ALL_DAYS
      t.hours.should == TimeProfile::ALL_HOURS
      t.tz.should == TimeProfile::DEFAULT_TZ
      t.entire_tz?.should be_true
    end
  end

  it "will return the correct values for tz_or_default" do
    t = TimeProfile.new
    t.tz_or_default.should == TimeProfile::DEFAULT_TZ
    t.tz_or_default("Hawaii").should == "Hawaii"

    t.tz = "Hawaii"
    t.tz.should == "Hawaii"
    t.tz_or_default.should == "Hawaii"
    t.tz_or_default("Alaska").should == "Hawaii"
  end

  it "will not rollup daily performances on create if rollups are disabled" do
    FactoryGirl.create(:time_profile)
    assert_nothing_queued
  end

  context "with an existing time profile with rollups disabled" do
    before(:each) do
      @tp = FactoryGirl.create(:time_profile)
      MiqQueue.delete_all
    end

    it "will not rollup daily performances if any changes are made" do
      @tp.update_attribute(:description, "New Description")
      assert_nothing_queued

      @tp.update_attribute(:days, [1, 2])
      assert_nothing_queued
    end

    it "will rollup daily performances if rollups are enabled" do
      @tp.update_attribute(:rollup_daily_metrics, true)
      assert_rebuild_daily_queued
    end
  end

  it "will rollup daily performances on create if rollups are enabled" do
    @tp = FactoryGirl.create(:time_profile_with_rollup)
    assert_rebuild_daily_queued
  end

  context "with an existing time profile with rollups enabled" do
    before(:each) do
      @tp = FactoryGirl.create(:time_profile_with_rollup)
      MiqQueue.delete_all
    end

    it "will not rollup daily performances if non-profile changes are made" do
      @tp.update_attribute(:description, "New Description")
      assert_nothing_queued
    end

    it "will rollup daily performances if profile changes are made" do
      @tp.update_attribute(:days, [1, 2])
      assert_rebuild_daily_queued
    end

    it "will not rollup daily performances if rollups are disabled" do
      @tp.update_attribute(:rollup_daily_metrics, false)
      assert_destroy_queued
    end
  end

  context "profiles_for_user" do
    before(:each) do
      TimeProfile.seed
    end

    it "gets time profiles for user and global default timeprofile" do
      tp = TimeProfile.find_by_description(TimeProfile::DEFAULT_TZ)
      tp.profile_type = "global"
      tp.save
      FactoryGirl.create(:time_profile,
                         :description          => "test1",
                         :profile_type         => "user",
                         :profile_key          => "some_user",
                         :rollup_daily_metrics => true)

      FactoryGirl.create(:time_profile,
                         :description          => "test2",
                         :profile_type         => "user",
                         :profile_key          => "foo",
                         :rollup_daily_metrics => true)
      tp = TimeProfile.profiles_for_user("foo", MiqRegion.my_region_number)
      tp.count.should == 2
    end
  end

  context "profile_for_user_tz" do
    before(:each) do
      TimeProfile.seed
    end

    it "gets time profiles that matches user's tz and marked for daily Rollup" do
      FactoryGirl.create(:time_profile,
                         :description          => "test1",
                         :profile_type         => "user",
                         :profile_key          => "some_user",
                         :tz                   => "other_tz",
                         :rollup_daily_metrics => true)

      FactoryGirl.create(:time_profile,
                         :description          => "test2",
                         :profile_type         => "user",
                         :profile_key          => "foo",
                         :tz                   => "foo_tz",
                         :rollup_daily_metrics => true)
      tp = TimeProfile.profile_for_user_tz("foo", "foo_tz")
      tp.description.should == "test2"
    end
  end

  describe "#profile_for_each_region" do
    it "returns none for a non rollup metric" do
      tp = FactoryGirl.create(:time_profile, :rollup_daily_metrics => false)

      expect(tp.profile_for_each_region).to eq([])
    end

    it "returns unique entries" do
      tp1a = FactoryGirl.create(:time_profile_with_rollup, :id => id_in_region(5, 1))
      tp1b = FactoryGirl.create(:time_profile_with_rollup, :id => id_in_region(5, 2))
      FactoryGirl.create(:time_profile_with_rollup, :days => [1, 2], :id => id_in_region(5, 3))
      FactoryGirl.create(:time_profile, :rollup_daily_metrics => false, :id => id_in_region(5, 4))
      tp2 = FactoryGirl.create(:time_profile_with_rollup, :id => id_in_region(6, 1))
      FactoryGirl.create(:time_profile_with_rollup, :days => [1, 2], :id => id_in_region(6, 2))
      FactoryGirl.create(:time_profile, :rollup_daily_metrics => false, :id => id_in_region(6, 3))

      results = tp1a.profile_for_each_region
      expect(results.size).to eq(2)
      expect(results.map(&:region_id)).to match_array([5, 6])
      expect(results.include?(tp1a) || results.include?(tp1b)).to be true
      expect(results).to include(tp2)
    end
  end

  describe ".all_timezones" do
    it "works with seeds" do
      FactoryGirl.create(:time_profile, :tz => "tz")
      FactoryGirl.create(:time_profile, :tz => "tz")
      FactoryGirl.create(:time_profile, :tz => "other_tz")

      expect(TimeProfile.all_timezones).to match_array(%w(tz other_tz))
    end
  end

  describe ".find_all_with_entire_tz" do
    it "only returns profiles with all days" do
      FactoryGirl.create(:time_profile, :days => [1, 2])
      tp = FactoryGirl.create(:time_profile)

      expect(TimeProfile.find_all_with_entire_tz).to eq([tp])
    end
  end

  describe ".profile_for_user_tz" do
    it "finds global profiles" do
      FactoryGirl.create(:time_profile_with_rollup, :tz => "good", :profile_type => "global")
      expect(TimeProfile.profile_for_user_tz(1, "good")).to be
    end

    it "finds user profiles" do
      FactoryGirl.create(:time_profile_with_rollup, :tz => "good", :profile_type => "user", :profile_key => 1)
      expect(TimeProfile.profile_for_user_tz(1, "good")).to be
    end

    it "skips invalid records" do
      FactoryGirl.create(:time_profile_with_rollup, :tz => "bad", :profile_type => "global")
      FactoryGirl.create(:time_profile, :tz => "good", :profile_type => "global", :rollup_daily_metrics => false)
      FactoryGirl.create(:time_profile_with_rollup, :tz => "good", :profile_type => "user", :profile_key => "2")

      expect(TimeProfile.profile_for_user_tz(1, "good")).not_to be
    end
  end

  private

  def id_in_region(region, id)
    region * MiqRegion::DEFAULT_RAILS_SEQUENCE_FACTOR + id
  end

  def assert_rebuild_daily_queued
    q_all = MiqQueue.all
    q_all.length.should == 1
    q_all[0].class_name.should == "TimeProfile"
    q_all[0].instance_id.should == @tp.id
    q_all[0].method_name.should == "rebuild_daily_metrics"
  end

  def assert_destroy_queued
    q_all = MiqQueue.all
    q_all.length.should == 1
    q_all[0].class_name.should == "TimeProfile"
    q_all[0].instance_id.should == @tp.id
    q_all[0].method_name.should == "destroy_metric_rollups"
  end

  def assert_nothing_queued
    MiqQueue.count.should == 0
  end
end

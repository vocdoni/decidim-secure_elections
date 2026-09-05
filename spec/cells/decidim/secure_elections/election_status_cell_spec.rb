# frozen_string_literal: true

require "spec_helper"

describe Decidim::SecureElections::ElectionStatusCell do
  # `state_for` reads nothing but the columns of ARCHITECTURE §4b, so it is
  # exercised here against a plain value object. That keeps the test on the
  # derivation itself — which the cards, the badge and the voting page depend on —
  # rather than on the persistence around it.
  let(:election_class) { Struct.new(:status, :start_at, :end_at, keyword_init: true) }

  def state_for(status:, start_at: nil, end_at: nil)
    described_class.state_for(election_class.new(status:, start_at:, end_at:))
  end

  describe ".state_for" do
    it "reports elections that have not reached the chain as drafts" do
      expect(state_for(status: "draft")).to eq(:draft)
    end

    it "reports an election being pushed on chain as publishing" do
      expect(state_for(status: "publishing")).to eq(:publishing)
    end

    it "reports a ready election with no calendar as ongoing" do
      expect(state_for(status: "ready")).to eq(:ongoing)
    end

    it "reports a ready election inside its calendar as ongoing" do
      expect(state_for(status: "ready", start_at: 1.hour.ago, end_at: 1.hour.from_now)).to eq(:ongoing)
    end

    it "reports a ready election before its start time as scheduled" do
      expect(state_for(status: "ready", start_at: 1.hour.from_now, end_at: 2.hours.from_now)).to eq(:scheduled)
    end

    # The upstream status lags the calendar: a process stays `ready` until the
    # chain notices it is over. The UI must not keep inviting people to vote.
    it "reports a ready election past its end time as ended" do
      expect(state_for(status: "ready", start_at: 2.hours.ago, end_at: 1.hour.ago)).to eq(:ended)
    end

    it "reports a paused election as paused even inside its calendar" do
      expect(state_for(status: "paused", start_at: 1.hour.ago, end_at: 1.hour.from_now)).to eq(:paused)
    end

    it "reports an ended election as ended" do
      expect(state_for(status: "ended")).to eq(:ended)
    end

    it "reports a published tally as results" do
      expect(state_for(status: "results", start_at: 2.hours.ago, end_at: 1.hour.ago)).to eq(:results)
    end

    it "reports a canceled election as canceled even inside its calendar" do
      expect(state_for(status: "canceled", start_at: 1.hour.ago, end_at: 1.hour.from_now)).to eq(:canceled)
    end

    it "falls back to draft for an unknown status rather than inviting votes" do
      expect(state_for(status: "something-new")).to eq(:draft)
    end
  end
end

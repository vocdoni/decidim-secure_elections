# frozen_string_literal: true

require "spec_helper"
require "decidim/elections/test/factories"

# Focused unit spec on the `auth_fields` reader — the only piece of
# {PublishElectionJob} that the Security-tab change touches. The full
# publish flow has its own integration coverage.
module Decidim
  module Elections
    module Vocdoni
      describe PublishElectionJob do
        let(:election) { create(:election) }

        def auth_fields_for(settings)
          sidecar = Vocdoni::Process.create!(decidim_election_id: election.id, state: "pending",
                                             metadata: { "settings" => settings })
          job = described_class.new
          job.instance_variable_set(:@election, election)
          job.instance_variable_set(:@process, sidecar)
          job.send(:auth_fields)
        end

        it "reads the sidecar-stored fields" do
          expect(auth_fields_for("auth_fields" => %w(nationalId memberNumber))).to eq(%w(nationalId memberNumber))
        end

        it "falls back to memberNumber when the key is absent" do
          expect(auth_fields_for("twofa_fields" => %w(email))).to eq(%w(memberNumber))
        end

        it "falls back to memberNumber when the value is blank" do
          expect(auth_fields_for("auth_fields" => [])).to eq(%w(memberNumber))
        end
      end
    end
  end
end

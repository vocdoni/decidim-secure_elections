# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe VoterAttestation do
        let(:organization) { create(:organization) }
        let(:component) { create(:elections_component, organization:) }
        let(:election) { create(:election, :ongoing, component:) }
        let!(:process) { create(:vocdoni_process, :published, election:, census_mode: "attested").tap(&:ensure_attestation_secrets!) }
        let(:user) { create(:user, :confirmed, organization:) }
        let(:row) { Decidim::Elections::Voter.create!(election:, data: { "email" => "row@example.org", "token" => "t" }) }

        it "reaches a user at the account email and a census row at its email column" do
          expect(described_class.contact_email(election, user.to_global_id.to_s)).to eq(user.email)
          expect(described_class.contact_email(election, row.to_global_id.to_s)).to eq("row@example.org")
        end

        it "has no contact for a voter outside the election's census" do
          outsider = create(:user, :confirmed)
          other_row = Decidim::Elections::Voter.create!(election: create(:election, component:), data: { "email" => "other@example.org" })

          expect(described_class.contact_email(election, outsider.to_global_id.to_s)).to be_nil
          expect(described_class.contact_email(election, other_row.to_global_id.to_s)).to be_nil
        end

        it "hands the booth of an attested election the attestation URL and the row's contact" do
          config = VotingBackend.booth_config(election, voter_uid: row.to_global_id.to_s)

          expect(config[:credentials]).to be_nil
          expect(config[:attestationUrl]).to end_with("/elections/#{election.id}/vocdoni_attestation")
          expect(config[:contact]).to eq(email: "row@example.org", masked: "r•••@example.org")
        end
      end
    end
  end
end

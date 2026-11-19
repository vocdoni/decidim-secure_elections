# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe VoterAttestation do
        let(:organization) { create(:organization) }
        let(:component) { create(:elections_component, organization:) }
        let(:election) { create(:election, :ongoing, component:) }
        let!(:process) { create(:vocdoni_process, :published, election:).tap(&:ensure_attestation_secrets!) }
        let(:user) { create(:user, :confirmed, organization:) }
        let(:row) { Decidim::Elections::Voter.create!(election:, data: { "email" => "row@example.org", "token" => "t" }) }

        it "reaches a user at the account email and a census row at its email column" do
          expect(described_class.contact(election, user.to_global_id.to_s, "email")).to eq(user.email.downcase)
          expect(described_class.contact(election, row.to_global_id.to_s, "email")).to eq("row@example.org")
        end

        it "reaches a voter at the E.164 form of their phone" do
          phone_row = Decidim::Elections::Voter.create!(election:, data: { "phone" => "+34 600 12 34 56", "token" => "p" })
          local_row = Decidim::Elections::Voter.create!(election:, data: { "phone" => "600123456", "token" => "l" })

          expect(described_class.contact(election, phone_row.to_global_id.to_s, "phone")).to eq("+34600123456")
          expect(described_class.contact(election, local_row.to_global_id.to_s, "phone")).to be_nil
          expect(described_class.contact(election, row.to_global_id.to_s, "phone")).to be_nil
        end

        it "has no contact for a voter outside the election's census" do
          outsider = create(:user, :confirmed)
          other_row = Decidim::Elections::Voter.create!(election: create(:election, component:), data: { "email" => "other@example.org" })

          expect(described_class.contact(election, outsider.to_global_id.to_s, "email")).to be_nil
          expect(described_class.contact(election, other_row.to_global_id.to_s, "email")).to be_nil
        end
      end
    end
  end
end

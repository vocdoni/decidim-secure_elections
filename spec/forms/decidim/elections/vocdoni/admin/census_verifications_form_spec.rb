# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    module Admin
      describe CensusVerificationsForm do
        subject(:form) { described_class.from_params(params).with_context(context) }

        let(:organization) { create(:organization, available_authorizations: ["dummy_authorization_handler"]) }
        let(:election) { create(:vocdoni_election) }
        let(:context) { { current_organization: organization, election: } }
        let(:params) { { census_verifications: { authorization_handler: handler } } }
        let(:handler) { "dummy_authorization_handler" }

        context "when somebody holds the verification" do
          before do
            user = create(:user, :confirmed, organization:)
            create(:authorization, :granted, name: handler, user:)
          end

          it { is_expected.to be_valid }
        end

        # `FormBuilder#error_for` renders the message on its own, with no
        # attribute name in front of it, so an ActiveModel-style fragment
        # reached the page reading "has not been granted to anybody yet, so it
        # would add no one to the census." — half a sentence, next to the field.
        context "when nobody holds it" do
          it { is_expected.to be_invalid }

          it "reads as a whole sentence where it is rendered" do
            form.invalid?

            expect(form.errors[:authorization_handler].join(" "))
              .to eq("This verification has not been granted to anybody yet, so it would add no one to the census. " \
                     "Choose another verification, or add people by hand.")
          end

          it "says what to do about it" do
            form.invalid?

            expect(form.errors[:authorization_handler].join(" ")).to include("add people by hand")
          end
        end

        # The one field on this panel that used to fall back to Decidim's
        # generic "There is an error in this field." — the only message here
        # that names neither the field nor the fix.
        context "when nothing was chosen" do
          let(:handler) { "" }

          it { is_expected.to be_invalid }

          it "says what to choose rather than that something is wrong" do
            form.invalid?

            expect(form.errors[:authorization_handler].join(" "))
              .to eq("Choose the verification to import from. Everybody who has been granted it joins the census.")
          end
        end

        context "when the organization does not offer the verification" do
          let(:handler) { "not_offered" }

          it "does not also complain that nobody holds it" do
            form.invalid?

            expect(form.errors[:authorization_handler].size).to eq(1)
          end
        end
      end
    end
  end
end
end

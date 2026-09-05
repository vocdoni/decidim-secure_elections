# frozen_string_literal: true

require "spec_helper"

module Decidim
  module SecureElections
    module Admin
      describe Permissions do
        subject { described_class.new(user, permission_action, context).permissions.allowed? }

        # There is deliberately no `be false` anywhere below.
        #
        # This class only ever grants (see its own comment): a component
        # permission class runs first in the chain and Decidim raises
        # `PermissionCannotBeDisallowedError` if a later class allows what an
        # earlier one disallowed. "Refused" therefore shows up as *unset*, which
        # `allowed?` reports by raising — hence "permission is not set" for every
        # case this class withholds. The chain's default is deny, so unset and
        # denied mean the same thing to a request; the difference only matters
        # here, where the class is asked in isolation.
        #
        # What stops a withheld action from actually happening is asserted
        # elsewhere: the controller concern redirects (spec/controllers) and the
        # commands and jobs refuse (spec/commands, spec/jobs).

        let(:organization) { create(:organization) }
        let(:user) { create(:user, :admin, :confirmed, organization:) }
        let(:election) { create(:vocdoni_election, :ready_to_publish) }
        let(:context) { { election: } }
        let(:permission_action) { Decidim::PermissionAction.new(**action) }

        context "when reading the election list" do
          let(:action) { { scope: :admin, action: :read, subject: :election } }

          it { is_expected.to be true }
        end

        context "when updating a draft election" do
          let(:action) { { scope: :admin, action: :update, subject: :election } }

          it { is_expected.to be true }

          context "and the election is on chain" do
            before { election.update!(vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a01") }

            it_behaves_like "permission is not set"
          end
        end

        context "when editing the census" do
          let(:action) { { scope: :admin, action: :update, subject: :census } }

          it { is_expected.to be true }

          context "and the election is on chain" do
            before { election.update!(vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a01") }

            it_behaves_like "permission is not set"
          end
        end

        # The wizard order, third net. The navigation disables the step and the
        # controller redirects; this only withholds the grant, because a
        # component permission class may never veto (see the class comment).
        describe "the wizard order" do
          context "when the ballot is opened before the election has a title" do
            let(:election) { create(:vocdoni_election, title: { en: "" }) }
            let(:action) { { scope: :admin, action: :read, subject: :question } }

            it_behaves_like "permission is not set"
          end

          context "when the census is opened before the ballot is finished" do
            let(:election) { create(:vocdoni_election) }
            let(:action) { { scope: :admin, action: :read, subject: :census } }

            it_behaves_like "permission is not set"
          end

          context "when the schedule is opened before the census is complete" do
            let(:election) { create(:vocdoni_election, :with_questions) }
            let(:action) { { scope: :admin, action: :read, subject: :calendar } }

            it_behaves_like "permission is not set"
          end

          context "when the schedule is opened with everything before it done" do
            let(:action) { { scope: :admin, action: :read, subject: :calendar } }

            it { is_expected.to be true }
          end

          context "when a content step is opened on an on-chain election" do
            let(:election) { create(:vocdoni_election, :on_chain) }
            let(:action) { { scope: :admin, action: :read, subject: :census } }

            it "stays readable, because an admin must see what was published" do
              expect(subject).to be true
            end
          end

          context "when a content step is *edited* on an on-chain election" do
            let(:election) { create(:vocdoni_election, :on_chain) }
            let(:action) { { scope: :admin, action: :update, subject: :question } }

            it_behaves_like "permission is not set"
          end
        end

        context "when publishing on chain" do
          let(:action) { { scope: :admin, action: :create, subject: :setup } }

          it { is_expected.to be true }

          context "and the census identifies nobody" do
            before { election.update!(census_auth_fields: []) }

            it_behaves_like "permission is not set"
          end

          context "and a question has a single answer" do
            before do
              election.questions.first.answers.last.destroy!
              election.reload
            end

            it_behaves_like "permission is not set"
          end

          context "and the module is not configured" do
            before { allow(Decidim::SecureElections).to receive(:api_key).and_return(nil) }

            it_behaves_like "permission is not set"
          end

          context "and the election is already on chain" do
            before { election.update!(vocdoni_process_id: "6885f0c2c1a4e2f0b1d33a01") }

            it_behaves_like "permission is not set"
          end
        end

        context "when opening the monitor" do
          let(:action) { { scope: :admin, action: :read, subject: :monitor } }

          it_behaves_like "permission is not set"

          context "and the election is on chain" do
            let(:election) { create(:vocdoni_election, :on_chain) }

            it { is_expected.to be true }
          end
        end

        context "when trashing an election" do
          let(:action) { { scope: :admin, action: :soft_delete, subject: :election } }
          let(:context) { { trashable_deleted_resource: election } }

          it { is_expected.to be true }

          context "and the election is running on chain" do
            let(:election) { create(:vocdoni_election, :on_chain, end_at: 2.days.from_now) }

            it_behaves_like "permission is not set"
          end

          context "and the election is over" do
            let(:election) { create(:vocdoni_election, :on_chain, end_at: 1.day.ago) }

            it { is_expected.to be true }
          end
        end

        context "when the user is not logged in" do
          let(:user) { nil }
          let(:action) { { scope: :admin, action: :read, subject: :election } }

          it_behaves_like "permission is not set"
        end

        context "when the scope is not admin" do
          let(:action) { { scope: :public, action: :read, subject: :election } }

          it_behaves_like "permission is not set"
        end
      end
    end
  end
end

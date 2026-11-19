# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe "Admin publish retry" do
        let(:organization) { component.organization }
        let(:component) { create(:elections_component) }
        let(:admin) { create(:user, :admin, :confirmed, organization:) }
        let(:headers) { { "HOST" => organization.host } }
        let(:election) { create(:election, :with_token_csv_census, component:) }
        let(:proxy) { Decidim::EngineRouter.admin_proxy(component) }

        before { login_as admin, scope: :user }

        context "when the last publish failed" do
          let(:election) { create(:election, :with_token_csv_census, :published, :ongoing, component:) }

          before { create(:vocdoni_process, :failed, election:) }

          it "re-enqueues the publish job and returns to the dashboard" do
            expect { post proxy.election_publish_retry_path(election), headers: }
              .to have_enqueued_job(PublishElectionJob).with(election.id)
            expect(response).to redirect_to(proxy.dashboard_election_path(election))
          end
        end

        context "when the election is already published" do
          before { create(:vocdoni_process, :published, election:) }

          it "enqueues nothing" do
            expect { post proxy.election_publish_retry_path(election), headers: }
              .not_to have_enqueued_job(PublishElectionJob)
            expect(response).to redirect_to(proxy.dashboard_election_path(election))
          end
        end
      end
    end
  end
end

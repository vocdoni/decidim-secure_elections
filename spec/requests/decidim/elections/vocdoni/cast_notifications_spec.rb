# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe "Cast notifications" do
        let(:organization) { component.organization }
        let(:component) { create(:elections_component) }
        let(:user) { create(:user, :confirmed, organization:) }
        let(:headers) { { "HOST" => organization.host } }
        let(:results_availability) { "real_time" }
        let(:election) do
          create(:election, :published, :ongoing, :with_internal_users_census, component:, results_availability:)
        end
        let!(:vocdoni_process) { create(:vocdoni_process, :published, election:) }
        let(:authenticated) { true }
        let(:path) { Decidim::EngineRouter.main_proxy(component).election_vocdoni_cast_notification_path(election) }

        before do
          # The census session is upstream's concern; here it is either valid or not.
          allow(election.census).to receive_messages(valid_user?: authenticated, voter_uid: "voter-#{user.id}")
          login_as user, scope: :user
        end

        it "starts a results sync and ignores whatever the body says" do
          expect { post(path, params: { election_id: 999, votes: [1, 2] }, headers:) }
            .to have_enqueued_job(SyncResultsAfterVoteJob).with(election.id, seen: 1)

          expect(response).to have_http_status(:no_content)
        end

        it "coalesces many notifications into one sync" do
          expect { 3.times { post(path, headers:) } }
            .to have_enqueued_job(SyncResultsAfterVoteJob).exactly(:once)

          expect(vocdoni_process.reload.live_sync_requests).to eq(3)
        end

        context "when the voter has no census session" do
          let(:authenticated) { false }

          it "is forbidden and enqueues nothing" do
            expect { post(path, headers:) }.not_to have_enqueued_job(SyncResultsAfterVoteJob)
            expect(response).to have_http_status(:forbidden)
          end
        end

        context "when the election does not show live results" do
          let(:results_availability) { "after_end" }

          it "accepts the notification but enqueues nothing" do
            expect { post(path, headers:) }.not_to have_enqueued_job(SyncResultsAfterVoteJob)
            expect(response).to have_http_status(:no_content)
          end
        end

        context "when a voter goes over the rate limit" do
          before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

          it "answers 429 without touching the sidecar" do
            CastNotificationsController::RATE_LIMIT.times { post(path, headers:) }
            expect(response).to have_http_status(:no_content)

            expect { post(path, headers:) }.not_to(change { vocdoni_process.reload.live_sync_requests })
            expect(response).to have_http_status(:too_many_requests)
          end
        end

        context "without a CSRF token" do
          around do |example|
            ActionController::Base.allow_forgery_protection = true
            example.run
          ensure
            ActionController::Base.allow_forgery_protection = false
          end

          it "is rejected" do
            expect do
              post(path, headers:)
            rescue ActionController::InvalidAuthenticityToken
              nil
            end.not_to have_enqueued_job(SyncResultsAfterVoteJob)

            expect(vocdoni_process.reload.live_sync_requests).to eq(0)
          end
        end
      end
    end
  end
end

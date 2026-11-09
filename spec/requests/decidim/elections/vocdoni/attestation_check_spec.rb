# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe "Voter attestation check" do
        let(:organization) { component.organization }
        let(:component) { create(:elections_component) }
        let(:headers) { { "HOST" => organization.host } }
        let(:election) { create(:election, :published, :finished, :with_token_csv_census, component:) }
        let!(:question) { create(:election_question, :with_response_options, election:) }
        let(:voter) { Decidim::Elections::Voter.create!(election:, data: { "email" => "voter@example.org", "token" => "t0k3n" }) }
        let(:voter_uid) { voter.to_global_id.to_s }
        let!(:process) do
          create(:vocdoni_process, :published, election:, census_mode: "attested",
                                               metadata: { "questions" => [{ "decidim_question_id" => question.id, "vocdoni_question_id" => "q1" }] })
            .tap(&:ensure_attestation_secrets!)
        end
        let(:voter_id) { process.voter_id_for(voter_uid).unpack1("H*") }
        let(:path) { Decidim::EngineRouter.main_proxy(component).election_vocdoni_attestation_path(election) }
        let(:html) { response.parsed_body }
        let(:authenticated) { true }

        before do
          allow_any_instance_of(AttestationsController).to receive(:session_authenticated?).and_return(authenticated) # rubocop:disable RSpec/AnyInstance
          allow_any_instance_of(AttestationsController).to receive(:voter_uid).and_return(voter_uid) # rubocop:disable RSpec/AnyInstance
        end

        def stub_participant(participants)
          stub_request(:get, "https://saas-api.example.org/processes/#{process.vocdoni_process_id}/participants")
            .with(query: { field: "voterId", value: voter_id })
            .to_return(status: 200, body: { participants: }.to_json, headers: { "Content-Type" => "application/json" })
        end

        it "lists the questions the SaaS signed a ballot on for the voter, with whether a vote is recorded" do
          stub_participant([{ voterId: voter_id, questions: [{ questionId: "q1", hasSigned: true, hasVoted: false }] }])

          get(path, headers:)

          expect(response).to have_http_status(:ok)
          expect(html.at_css("[data-attestation-check]")["data-attestation-check"]).to eq("signed")
          item = html.at_css("li[data-question-id='q1']").text
          expect(item).to include(translated(question.body))
          expect(item).to include("no vote is recorded")
        end

        it "says so when the SaaS signed nothing for the voter" do
          stub_participant([])

          get(path, headers:)

          expect(html.at_css("[data-attestation-check]")["data-attestation-check"]).to eq("none")
        end

        it "asks the voter to come back while the election is open" do
          election.update!(end_at: 1.day.from_now)

          get(path, headers:)

          expect(html.at_css("[data-attestation-check]")["data-attestation-check"]).to eq("pending")
        end

        it "reports the SaaS being unreachable" do
          stub_request(:get, %r{/participants}).to_return(status: 503)

          get(path, headers:)

          expect(html.at_css("[data-attestation-check]")["data-attestation-check"]).to eq("unavailable")
        end

        context "when the census access has not let the voter in" do
          let(:authenticated) { false }

          it "sends them to the census check first" do
            get(path, headers:)

            expect(response).to redirect_to(Decidim::EngineRouter.main_proxy(component).new_election_census_check_path(election))
          end
        end
      end
    end
  end
end

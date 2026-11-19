# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe "Admin Dashboard attestation audit" do
        let(:organization) { component.organization }
        let(:component) { create(:elections_component) }
        let(:admin) { create(:user, :admin, :confirmed, organization:) }
        let(:headers) { { "HOST" => organization.host } }
        let!(:election) { create(:election, :published, :finished, :with_token_csv_census, component:) }
        let!(:question) { create(:election_question, :with_response_options, election:) }
        let!(:process) do
          create(:vocdoni_process, :published, election:,
                                               metadata: { "questions" => [{ "decidim_question_id" => question.id, "vocdoni_question_id" => "q1" }] })
        end
        let(:dashboard_path) { Decidim::EngineRouter.admin_proxy(component).dashboard_election_path(election) }
        let(:card) { response.parsed_body.at_css("[data-attestation-audit]") }

        before do
          process.record_issued_attestation!("0x#{"aa" * 32}")
          stub_request(:get, "https://saas-api.example.org/processes/#{process.vocdoni_process_id}/attestations")
            .with(query: { page: 1, limit: 100 })
            .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: {
              maxCensusSize: 12, pagination: { lastPage: 1 },
              attestations: [{ voterId: "aa" * 32, questions: [{ questionId: "q1" }] }, { voterId: "cc" * 32, questions: [{ questionId: "q1" }] }]
            }.to_json)
          login_as admin, scope: :user
          get dashboard_path, headers:
        end

        it "shows issued against published attestations, the unknown ones and each question's signed count" do
          expect(response).to have_http_status(:ok)
          expect(card.at_css("[data-audit-issued]").text).to include("Issued: 1 attestation to 1 voter.")
          expect(card.at_css("[data-audit-published]").text).to include("2 signed voters, out of a declared maximum of 12")
          expect(card.at_css("[data-audit-unknown]").text).to include("never attested: 1")
          expect(card.at_css("[data-audit-question='q1']").text).to include("2 signed voters")
        end

        context "when counts differ from one" do
          before do
            process.record_issued_attestation!("0x#{"aa" * 32}")
            process.record_issued_attestation!("0x#{"bb" * 32}")
            stub_request(:get, "https://saas-api.example.org/processes/#{process.vocdoni_process_id}/attestations")
              .with(query: { page: 1, limit: 100 })
              .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: {
                maxCensusSize: 12, pagination: { lastPage: 1 }, attestations: [{ voterId: "aa" * 32, questions: [{ questionId: "q1" }] }]
              }.to_json)
            get dashboard_path, headers:
          end

          it "pluralizes each count on its own" do
            expect(card.at_css("[data-audit-issued]").text).to include("Issued: 3 attestations to 2 voters.")
            expect(card.at_css("[data-audit-published]").text).to include("Published by Vocdoni: 1 signed voter, out of a declared maximum of 12.")
            expect(card.at_css("[data-audit-unknown]").text).to include("never attested: 0.")
            expect(card.at_css("[data-audit-question='q1']").text).to include("1 signed voter.")
          end
        end

        it "has one and other forms for every count in every locale" do
          scope = "decidim.elections.vocdoni.admin.dashboard.attestations"
          %w(issued voters published unknown per_question).product([:en, :es, :ca]).each do |key, locale|
            expect(I18n.t("#{scope}.#{key}", locale:)).to include(:one, :other), "#{locale}: #{key}"
          end
        end

        context "when the election is not on the SaaS yet" do
          let!(:process) { create(:vocdoni_process, election:) }

          it "shows no audit" do
            expect(response).to have_http_status(:ok)
            expect(card).to be_nil
          end
        end
      end
    end
  end
end

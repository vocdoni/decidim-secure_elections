# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe "Voter attestations" do
        let(:organization) { component.organization }
        let(:component) { create(:elections_component) }
        let(:headers) { { "HOST" => organization.host } }
        let(:election) { create(:election, :published, :ongoing, :with_token_csv_census, component:) }
        let(:voter) { Decidim::Elections::Voter.create!(election:, data: { "email" => " Voter@Example.org", "token" => "t0k3n" }) }
        let(:voter_uid) { voter.to_global_id.to_s }
        let(:contract) { "0x#{"cd" * 20}" }
        let(:settings) { { "twofa_fields" => ["email"] } }
        let!(:process) do
          create(:vocdoni_process, :published, election:, census_mode: "attested",
                                               metadata: { "settings" => settings, "attestation_verifying_contract" => contract }).tap(&:ensure_attestation_secrets!)
        end
        let(:path) { Decidim::EngineRouter.main_proxy(component).election_vocdoni_attestation_path(election) }
        let(:body) { response.parsed_body }
        let(:authenticated) { true }

        before do
          allow_any_instance_of(AttestationsController).to receive(:session_authenticated?).and_return(authenticated) # rubocop:disable RSpec/AnyInstance
          allow_any_instance_of(AttestationsController).to receive(:voter_uid).and_return(voter_uid) # rubocop:disable RSpec/AnyInstance
        end

        def digest_of(attestation)
          Attestation.digest(
            Attestation.hex_to_bytes(contract),
            process_id: Attestation.hex_to_bytes(attestation["processId"]),
            voter_id: Attestation.hex_to_bytes(attestation["voterId"]),
            contact_hash: Attestation.hex_to_bytes(attestation["contactHash"]),
            expires_at: attestation["expiresAt"]
          )
        end

        it "signs an attestation the election's signer recovers to, with the contact that opens it" do
          post(path, headers:)

          expect(response).to have_http_status(:ok)
          attestation = body["attestation"]
          signer = Attestation.recover(digest_of(attestation), Attestation.hex_to_bytes(body["signature"]))
          expect(Attestation.bytes_to_hex(signer)).to eq(process.signer_address)
          expect(attestation["processId"]).to eq(process.vocdoni_process_id)
          expect(attestation["voterId"]).to eq(process.voter_id_for(voter_uid).unpack1("H*"))
          expect(attestation["expiresAt"]).to be_within(5).of(10.minutes.from_now.to_i)
          expect(body["contact"]).to eq("voter@example.org")
          expect(attestation["contactHash"]).to eq(
            Attestation.contact_hash(Attestation.hex_to_bytes(body["salt"]), "email", "voter@example.org").unpack1("H*")
          )
        end

        it "draws a fresh salt and counts every attestation issued" do
          salts = Array.new(3) do
            post(path, headers:)
            response.parsed_body["salt"]
          end

          expect(salts.uniq.size).to eq(3)
          expect(process.issued_attestations.sole.issued_count).to eq(3)
        end

        context "without 2FA" do
          let(:settings) { { "twofa_fields" => [] } }

          it "commits to no contact" do
            post(path, headers:)

            expect(body["attestation"]["contactHash"]).to eq("00" * 32)
            expect(body).not_to have_key("contact")
            expect(body).not_to have_key("salt")
          end
        end

        context "when the census access has not let the voter in" do
          let(:authenticated) { false }

          it "refuses" do
            post(path, headers:)

            expect(response).to have_http_status(:unauthorized)
            expect(process.issued_attestations).to be_empty
          end
        end

        context "when the census row has no email" do
          let(:voter) { Decidim::Elections::Voter.create!(election:, data: { "token" => "t0k3n" }) }

          it "refuses with email 2FA" do
            post(path, headers:)

            expect(response).to have_http_status(:unprocessable_content)
          end
        end

        context "when the election does not use an attested census" do
          before { process.update!(census_mode: "memberbase") }

          it "answers not found" do
            post(path, headers:)

            expect(response).to have_http_status(:not_found)
          end
        end

        context "when the verifyingContract is not known yet" do
          before { process.update!(metadata: { "settings" => settings }) }

          it "reads it from the SaaS process once" do
            stub = stub_request(:get, "https://saas-api.example.org/processes/#{process.vocdoni_process_id}")
                   .to_return(status: 200, body: { census: { attested: { verifyingContract: contract } } }.to_json,
                              headers: { "Content-Type" => "application/json" })

            2.times { post(path, headers:) }

            expect(response).to have_http_status(:ok)
            expect(stub).to have_been_requested.once
            expect(process.reload.metadata["attestation_verifying_contract"]).to eq(contract)
          end
        end

        context "when the voter has already hit the issuance cap" do
          before do
            voter_id = Decidim::Elections::Vocdoni::Attestation.bytes_to_hex(process.voter_id_for(voter_uid))
            process.issued_attestations.create!(voter_id:, issued_count: AttestationsController::MAX_ATTESTATIONS_PER_VOTER)
          end

          it "refuses with 429" do
            post(path, headers:)

            expect(response).to have_http_status(:too_many_requests)
            expect(process.issued_attestations.sole.issued_count).to eq(AttestationsController::MAX_ATTESTATIONS_PER_VOTER)
          end
        end
      end
    end
  end
end

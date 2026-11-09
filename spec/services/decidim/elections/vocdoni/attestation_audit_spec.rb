# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
      describe AttestationAudit do
        subject(:audit) { described_class.new(process).call }

        let(:election) { create(:election, :published, :finished) }
        let(:process) { create(:vocdoni_process, :published, election:, census_mode: "attested") }
        let(:url) { "https://saas-api.example.org/processes/#{process.vocdoni_process_id}/attestations" }
        let(:json_headers) { { "Content-Type" => "application/json" } }

        def page(number, records, last_page)
          stub_request(:get, url).with(query: { page: number, limit: 100 })
                                 .to_return(status: 200, headers: json_headers, body: {
                                   maxCensusSize: 12, attestations: records, pagination: { currentPage: number, lastPage: last_page }
                                 }.to_json)
        end

        before do
          process.record_issued_attestation!("0x#{"aa" * 32}")
          process.record_issued_attestation!("0x#{"aa" * 32}")
          process.record_issued_attestation!("0x#{"bb" * 32}")
        end

        it "holds every published page against the attestations Decidim issued" do
          page(1, [{ voterId: "aa" * 32, questions: [{ questionId: "q1" }, { questionId: "q2" }] }], 2)
          page(2, [{ voterId: "cc" * 32, questions: [{ questionId: "q1" }] }], 2)

          expect(audit).to eq(
            issued_voters: 2, issued_total: 3, published: 2, unknown: 1,
            per_question: { "q1" => 2, "q2" => 1 }, max_census_size: 12
          )
        end

        it "reports the records as pending while the SaaS withholds them" do
          stub_request(:get, url).with(query: hash_including({})).to_return(status: 409, headers: json_headers, body: { error: "not ended" }.to_json)

          expect(audit).to include(issued_voters: 2, unavailable: :pending)
        end

        it "only counts issued attestations while the election is open" do
          election.update!(end_at: 1.day.from_now)

          expect(audit).to eq(issued_voters: 2, issued_total: 3)
        end
      end
    end
  end
end

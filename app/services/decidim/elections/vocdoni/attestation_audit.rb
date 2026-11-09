# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Holds what Decidim issued for an attested election against what the SaaS publishes once
      # it has ended: every published voterId should be one Decidim issued, and each question's
      # signed count should stay within the declared census size.
      class AttestationAudit
        PAGE_SIZE = 100

        def initialize(process)
          @process = process
        end

        # @return [Hash] `issued_voters` and `issued_total` always; after the end, `published`,
        #   `unknown`, `per_question` (SaaS question id => signed voterIds) and `max_census_size`,
        #   or `unavailable` (:pending while the SaaS withholds the records, :error otherwise).
        def call
          issued = process.issued_attestations
          result = { issued_voters: issued.count, issued_total: issued.sum(:issued_count) }
          return result unless process.election.finished? && process.vocdoni_process_id.present?

          result.merge(published_summary(issued.pluck(:voter_id).to_set { |id| normalize(id) }))
        end

        private

        attr_reader :process

        def published_summary(known)
          records, max_census_size = published_records
          {
            published: records.size,
            unknown: records.count { |record| known.exclude?(normalize(record["voterId"])) },
            per_question: records.flat_map { |record| Array(record["questions"]).map { |q| q["questionId"] } }.tally,
            max_census_size:
          }
        rescue ApiError => e
          { unavailable: e.status == 409 ? :pending : :error }
        end

        def published_records
          client = ApiClient.new.elections
          records = []
          page = 1
          loop do
            body = client.attestations(process.vocdoni_process_id, page:, limit: PAGE_SIZE).to_h
            records.concat(Array(body["attestations"]))
            last_page = body.dig("pagination", "lastPage").to_i
            raise ApiError.new("attestations response has no pagination", transient: false) if last_page < 1
            return [records, body["maxCensusSize"]] if page >= last_page

            page += 1
          end
        end

        def normalize(voter_id) = voter_id.to_s.downcase.delete_prefix("0x")
      end
    end
  end
end

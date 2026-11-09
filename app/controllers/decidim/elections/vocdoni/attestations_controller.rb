# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # The booth of an attested election fetches its voter's attestation here and forwards it to
      # the SaaS CSP's auth/0. Each call signs a fresh one with a fresh salt; the voter is the one
      # Decidim's census access let into the booth.
      #
      # After the end, `show` tells the voter on which questions the SaaS reports having signed a
      # ballot for them: a question they never voted on exposes a signature issued in their name.
      class AttestationsController < Decidim::Elections::ApplicationController
        # Maximum attestations a voter may request per election, bounding CPU on ECDSA and issued_total growth.
        MAX_ATTESTATIONS_PER_VOTER = 50
        include Decidim::Elections::UsesCensusAccess

        helper_method :signed_questions, :check_state

        def show
          enforce_permission_to(:read, :election, election:)
          return redirect_to(router.new_election_census_check_path(election)) unless session_authenticated? && voter_uid.present?
          return head(:not_found) unless attested_process

          @check_state = election.finished? ? signed_state : :pending
        end

        def create
          enforce_permission_to(:create, :vote, election:)
          return head(:unauthorized) unless session_authenticated? && voter_uid.present?
          return head(:not_found) unless attested_process&.published?

          voter_id = Decidim::Elections::Vocdoni::Attestation.bytes_to_hex(attested_process.voter_id_for(voter_uid))
          issued = attested_process.issued_attestations.where(voter_id:).pick(:issued_count).to_i
          return head(:too_many_requests) if issued >= MAX_ATTESTATIONS_PER_VOTER

          render json: VoterAttestation.new(attested_process, voter_uid).call
        rescue VoterAttestation::NoContact
          head :unprocessable_content
        rescue Decidim::Elections::Vocdoni::ApiError
          head :bad_gateway
        end

        private

        attr_reader :check_state, :signed_questions

        def router = Decidim::EngineRouter.main_proxy(current_component)

        def attested_process
          process = election.vocdoni_process
          process if process&.attested? && process.vocdoni_process_id.present?
        end

        # :signed with @signed_questions set, :none when the SaaS signed nothing for the voter.
        def signed_state
          process = attested_process
          voter_id = Attestation.bytes_to_hex(process.voter_id_for(voter_uid))
          entry = ApiClient.new.elections.attested_participant(process.vocdoni_process_id, voter_id)
          signed = Array(entry && entry["questions"]).select { |question| question["hasSigned"] }
          return :none if signed.empty?

          @signed_questions = signed.map { |question| local_question(process, question) }
          :signed
        rescue Decidim::Elections::Vocdoni::ApiError
          :unavailable
        end

        def local_question(process, remote)
          row = process.questions_metadata.find { |meta| meta["vocdoni_question_id"].to_s == remote["questionId"].to_s } || {}
          { question: election.questions.find_by(id: row["decidim_question_id"]), id: remote["questionId"], voted: remote["hasVoted"] }
        end
      end
    end
  end
end

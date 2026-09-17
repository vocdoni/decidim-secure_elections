# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module Admin
        # Persists the Security-tab choices onto the {Process} sidecar.
        #
        # The sidecar's presence is the opt-in signal used by the phase-4
        # publish subscription — if it exists, publish enqueues
        # {PublishToVocdoniJob}. Its `metadata["settings"]` hash carries the
        # second-factor selection ({SecurityForm#two_fa_fields}) that the job
        # forwards verbatim as `twoFaFields`.
        #
        # Semantics of the `enable_vocdoni` toggle:
        #   * OFF, no sidecar    → nothing to do.
        #   * OFF, sidecar exists, election still editable → delete sidecar
        #     (opt out; the election reverts to a plain Decidim election).
        #   * OFF, sidecar exists, election locked (published) → refuse:
        #     the on-chain process cannot be un-published from here.
        #   * ON, no sidecar     → create it in `pending`.
        #   * ON, sidecar exists → update `metadata["settings"]`.
        class UpdateElectionSecurity < Decidim::Command
          # @param form     [AdminForms::SecurityForm]
          # @param election [Decidim::Elections::Election]
          def initialize(form, election)
            @form = form
            @election = election
          end

          def call
            return broadcast(:invalid) if form.invalid?
            return broadcast(:invalid) unless election.editable?

            if form.enable_vocdoni
              enable!
              PreflightTrigger.call(election.reload)
            else
              disable!
            end

            broadcast(:ok)
          end

          private

          attr_reader :form, :election

          def enable!
            sidecar = election.vocdoni_process || Process.new(decidim_election_id: election.id, state: "pending")
            sidecar.metadata = sidecar.metadata.to_h.merge(
              "settings" => { "twofa_fields" => form.two_fa_fields }
            )
            sidecar.save!
          end

          def disable!
            sidecar = election.vocdoni_process
            return if sidecar.blank?
            return if sidecar.published?

            sidecar.destroy!
          end
        end
      end
    end
  end
end

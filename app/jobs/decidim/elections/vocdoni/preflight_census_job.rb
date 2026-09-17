# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Runs the census pre-flight ({PublishToVocdoniJob.preview_census!}) out
      # of the admin's request: pushing a roster to the memberbase and
      # validating it can take tens of seconds. Enqueued by {PreflightTrigger}.
      class PreflightCensusJob < ApplicationJob
        queue_as :vocdoni_spike

        # The trigger may run inside upstream's census transaction; the job
        # must see the committed census.
        self.enqueue_after_transaction_commit = true

        def perform(election_id)
          PublishToVocdoniJob.preview_census!(election_id)
        end
      end
    end
  end
end

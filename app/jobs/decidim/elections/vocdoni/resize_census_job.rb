# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      # Raises the census size declared on chain when the roster of an
      # external-CSP process outgrows it. The sign endpoint enqueues it at most
      # once a minute per process.
      class ResizeCensusJob < ApplicationJob
        queue_as :vocdoni

        def perform(process_id); end
      end
    end
  end
end

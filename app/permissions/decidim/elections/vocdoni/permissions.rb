# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
    # Entry point of the component's permission chain. Admin checks are handed
    # over to `Decidim::Elections::Vocdoni::Admin::Permissions`.
    class Permissions < Decidim::DefaultPermissions
      def permissions
        return Decidim::Elections::Vocdoni::Admin::Permissions.new(user, permission_action, context).permissions if permission_action.scope == :admin
        return permission_action if permission_action.scope != :public

        allowed_election_action?
        allowed_vote_action?

        permission_action
      end

      private

      def election
        @election ||= context.fetch(:election, nil)
      end

      def allowed_election_action?
        return false unless permission_action.subject == :election

        allow! if permission_action.action == :read && election.present? && election.published?
      end

      # Eligibility itself is decided by the Vocdoni census in the voter's
      # browser. This only governs whether Decidim lets the voting page be reached at
      # all, so that an admin can additionally require a Decidim verification.
      def allowed_vote_action?
        return false unless permission_action.subject == :vote

        return false unless permission_action.action == :create

        allow! if election.present? && election.published? && election.on_chain? && election.ongoing?
      end
    end
  end
end
end

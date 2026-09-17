# frozen_string_literal: true

module Decidim
  module Elections
    module Vocdoni
      module AdminForms
        # The details a voter of a file census types to prove who they are.
        #
        # Shared by the two forms that can set them: the last step of the
        # upload wizard ({CensusFileMappingForm}, checking the rows it is about
        # to import) and the "Change" form on the Census tab
        # ({CensusIdentifiersForm}, checking the rows already imported). The
        # rules are the same either way, so they live here rather than in two
        # places that would drift.
        #
        # The vote type is not known here — it is chosen later, on the Security
        # tab — so the choice is checked against everything a simple vote
        # accepts. A secret vote accepts fewer ({CensusCsv::Fields::AUTH}); the
        # Security tab refuses the secret card and says why, instead of
        # silently dropping a detail the admin picked.
        #
        # A host must provide:
        #   `available_fields`      the columns the list has, in file order
        #   `identifier_duplicates` how many people the choice cannot tell apart
        module ChoosesIdentifiers
          extend ActiveSupport::Concern

          Fields = CensusCsv::Fields

          included do
            attribute :identifiers, Array[String], default: [] # rubocop:disable Style/RedundantArrayConstructor -- Decidim attribute type
            validate :identifiers_count, :identifiers_allowed, :identifiers_unique, if: :identifiers_checkable?
          end

          # There is nothing to check a choice against while the list itself is
          # unreadable; the host says when its columns are known.
          def identifiers_checkable?
            true
          end

          # Every column that can ever be an identifier, in file order.
          def identifier_options
            available_fields & Fields::SIMPLE_IDENTIFIERS
          end

          # What gets stored: the chosen columns the list actually has.
          def chosen_identifiers
            identifier_options & submitted_identifiers
          end

          # The checkboxes are preceded by an empty hidden field, which is how
          # "none of them" reaches the server at all; it is not a choice.
          def submitted_identifiers
            Array(identifiers).map(&:to_s).compact_blank
          end

          def identifier_selected?(field)
            chosen_identifiers.include?(field)
          end

          # Works for a secret, verifiable vote — either as a detail the
          # service checks, or as the address a one-time code is sent to.
          def usable_for_secure?(field)
            Fields::SECURE_IDENTIFIERS.include?(field)
          end

          # Choosing this detail also turns the one-time code on: it is what
          # proves the person, since the service cannot check a contact detail
          # against anything.
          def sends_code?(field)
            Fields::TWO_FA.include?(field)
          end

          # Chosen details that will send a code. Empty for a simple vote,
          # which has no code to send.
          def code_identifiers
            chosen_identifiers & Fields::TWO_FA
          end

          # Only name, surname or date of birth: details other people are
          # likely to know.
          def weak_identifiers?
            chosen = chosen_identifiers
            chosen.any? && (chosen - Fields::WEAK).empty?
          end

          private

          def identifiers_count
            count = chosen_identifiers.size
            return if count.between?(1, Fields::MAX_IDENTIFIERS)

            errors.add(:identifiers, count.zero? ? :blank : :too_many, count: Fields::MAX_IDENTIFIERS)
          end

          def identifiers_allowed
            refused = submitted_identifiers - identifier_options
            return if refused.empty?

            errors.add(:identifiers, :unknown)
          end

          def identifiers_unique
            return if errors[:identifiers].any?

            repeated = identifier_duplicates(chosen_identifiers)
            return if repeated.zero?

            errors.add(:identifiers, :not_unique, count: repeated, fields: identifier_labels(chosen_identifiers))
          end

          def identifier_labels(fields)
            fields.map { |field| Fields.label(field) }.to_sentence
          end
        end
      end
    end
  end
end

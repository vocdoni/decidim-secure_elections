# frozen_string_literal: true

require "decidim/components/namer"

module Decidim
  module SecureElections
    # Seeds for the Vocdoni component, invoked by `component.seeds` in
    # `lib/decidim/secure_elections/component.rb`.
    #
    # These seeds **never call the Vocdoni API**. `rake db:seed` has to work on
    # a laptop with no credentials, no network and no Vocdoni organization, so
    # everything created here is a local draft: `vocdoni_process_id` stays nil,
    # `status` stays `"draft"` and no background job is enqueued.
    #
    # The practical consequence is that a seeded election is fully editable and
    # walks the whole admin wizard, right up to — but not through — the
    # irreversible "publish on the blockchain" step.
    class Seeds < Decidim::Seeds
      # How many voters each seeded election gets. Enough to exercise the census
      # table and the "missing field" reporting without bloating the seed run.
      CENSUS_MEMBERS = 5

      attr_reader :participatory_space

      def initialize(participatory_space:)
        @participatory_space = participatory_space
      end

      def call
        component = create_component!
        total = number_of_records

        total.times do |index|
          # When several elections are seeded the last one is left unpublished,
          # so the admin index shows both states.
          election = create_election!(component:, published: total == 1 || index < total - 1)
          create_questions_for!(election)
          create_census_members_for!(election)
        end
      end

      private

      # A local census, which is what this module works from: the
      # Vocdoni group is created from these people at publish time, not seeded.
      def create_census_members_for!(election)
        CENSUS_MEMBERS.times do |index|
          Decidim::SecureElections::CensusMember.create!(
            election:,
            name: ::Faker::Name.first_name,
            surname: ::Faker::Name.last_name,
            email: "voter-#{election.id}-#{index + 1}@example.org",
            member_number: format("%04d", index + 1),
            weight: 1
          )
        end
      end

      def create_component!
        params = {
          name: Decidim::Components::Namer.new(participatory_space.organization.available_locales, :vocdoni).i18n_name,
          published_at: Time.current,
          manifest_name: :vocdoni,
          participatory_space:
        }

        Decidim.traceability.perform_action!(
          "publish",
          Decidim::Component,
          admin_user,
          visibility: "all"
        ) do
          Decidim::Component.create!(params)
        end
      end

      def create_election!(component:, published:)
        params = {
          component:,
          title: Decidim::Faker::Localized.sentence(word_count: 3),
          description: Decidim::Faker::Localized.wrapped("<p>", "</p>") do
            Decidim::Faker::Localized.paragraph(sentence_count: 3)
          end,
          # Left blank on purpose: an election with no start time opens as soon
          # as it is published on chain, which is the common case.
          start_at: nil,
          end_at: 1.week.from_now,
          status: "draft",
          published_at: published ? Time.current : nil,
          census_auth_fields: ["memberNumber"],
          census_two_fa_fields: []
          # Deliberately no `census_group_id` / `census_size`: those are caches
          # the publish job fills in from Vocdoni. Seeding them would fake an
          # upstream census that does not exist. The voters below are the real
          # local census, which is what `census_complete?` checks.
        }

        Decidim.traceability.perform_action!(
          "create",
          Decidim::SecureElections::Election,
          admin_user,
          visibility: "all"
        ) do
          Decidim::SecureElections::Election.create!(params)
        end
      end

      # One single choice and one multiple choice question, so both ballot
      # encodings are represented. Every question gets at least two answers,
      # which is what `Question#complete?` requires.
      def create_questions_for!(election)
        create_question!(election:, position: 0, question_type: "singlechoice", answers_count: 3)
        create_question!(election:, position: 1, question_type: "multichoice", answers_count: 4)
      end

      def create_question!(election:, position:, question_type:, answers_count:)
        multichoice = question_type == "multichoice"

        question = Decidim::SecureElections::Question.create!(
          election:,
          position:,
          question_type:,
          title: Decidim::Faker::Localized.sentence(word_count: 5),
          description: Decidim::Faker::Localized.paragraph(sentence_count: 2),
          min_choices: multichoice ? 1 : nil,
          max_choices: multichoice ? 2 : nil,
          secret_until_the_end: multichoice
        )

        answers_count.times do |value|
          Decidim::SecureElections::Answer.create!(
            question:,
            title: Decidim::Faker::Localized.sentence(word_count: 2),
            # 0-based and contiguous: this is the value encoded in the ballot.
            value:,
            position: value
          )
        end

        question
      end
    end
  end
end

# frozen_string_literal: true

require "decidim/components/namer"
require "decidim/faker/localized"
require "decidim/core/test/factories"
require "decidim/participatory_processes/test/factories"

# Guarded so that requiring this file twice — which happens as soon as a second
# module depends on it — redefines nothing.
unless FactoryBot::Internal.factories.registered?(:vocdoni_component)
  FactoryBot.define do
    factory :vocdoni_component, parent: :component do
      transient do
        skip_injection { false }
      end

      name { generate_component_name(participatory_space.organization.available_locales, :vocdoni, skip_injection:) }
      manifest_name { :vocdoni }
      participatory_space { create(:participatory_process, :with_steps, skip_injection:, organization:) }
    end

    factory :vocdoni_election, class: "Decidim::SecureElections::Election" do
      transient do
        skip_injection { false }
      end

      title { generate_localized_title(:vocdoni_election_title, skip_injection:) }
      description { generate_localized_description(:vocdoni_election_description, skip_injection:) }
      component { create(:vocdoni_component, skip_injection:) }

      start_at { nil }
      end_at { 2.days.from_now }
      status { "draft" }
      published_at { nil }
      deleted_at { nil }

      # A census that actually identifies somebody *and* has somebody in it.
      # Without both an election is not publishable, which is the point:
      # authentication rules with nobody behind them enfranchise no one, and
      # people with no rules enfranchise everyone.
      #
      # `census_group_id` is deliberately absent — it is written by the publish
      # job and never entered by hand.
      trait :with_census do
        transient do
          census_members_count { 3 }
        end

        census_auth_fields { ["memberNumber"] }

        after(:create) do |election, evaluator|
          evaluator.census_members_count.times do |index|
            create(
              :vocdoni_census_member,
              election:,
              member_number: format("%06d", index + 1),
              email: "voter-#{index + 1}-#{election.id}@example.org"
            )
          end
          election.update!(census_size: election.census_members.count)
        end
      end

      trait :two_factor do
        census_two_fa_fields { ["email"] }
      end

      trait :weighted do
        weighted { true }
      end

      trait :published do
        published_at { 1.day.ago }
      end

      trait :with_questions do
        transient do
          questions_count { 1 }
          answers_count { 2 }
        end

        after(:create) do |election, evaluator|
          evaluator.questions_count.times do |index|
            create(
              :vocdoni_question,
              :with_answers,
              election:,
              position: index,
              answers_count: evaluator.answers_count,
              skip_injection: evaluator.skip_injection
            )
          end
          election.reload
        end
      end

      # Everything the wizard requires, still off chain.
      trait :ready_to_publish do
        with_census
        with_questions
      end

      trait :on_chain do
        with_census
        with_questions
        vocdoni_process_id { "6885f0c2c1a4e2f0b1d33a01" }
        vocdoni_chain_id { "vocdoni/LTS/1.2" }
        status { "ready" }
        published_at { 1.day.ago }

        after(:create) do |election|
          election.questions.each_with_index do |question, index|
            question.update!(
              vocdoni_question_id: "6885f0c2c1a4e2f0b1d33a#{format("%02d", index + 2)}",
              vocdoni_upstream_id: "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a4#{format("%02d", index)}",
              vocdoni_status: "ready"
            )
          end
        end
      end
    end

    factory :vocdoni_question, class: "Decidim::SecureElections::Question" do
      transient do
        skip_injection { false }
        answers_count { 2 }
      end

      title { generate_localized_title(:vocdoni_question_title, skip_injection:) }
      description { generate_localized_description(:vocdoni_question_description, skip_injection:) }
      question_type { "singlechoice" }
      position { 0 }
      election { create(:vocdoni_election, skip_injection:) }

      trait :multichoice do
        question_type { "multichoice" }
        min_choices { 1 }
        max_choices { 2 }
      end

      trait :secret do
        secret_until_the_end { true }
      end

      trait :with_answers do
        after(:create) do |question, evaluator|
          evaluator.answers_count.times do |index|
            create(:vocdoni_answer, question:, value: index, position: index, skip_injection: evaluator.skip_injection)
          end
          question.reload
        end
      end
    end

    factory :vocdoni_answer, class: "Decidim::SecureElections::Answer" do
      transient do
        skip_injection { false }
      end

      title { generate_localized_title(:vocdoni_answer_title, skip_injection:) }
      value { 0 }
      position { 0 }
      question { create(:vocdoni_question, skip_injection:) }
    end

    factory :vocdoni_census_member, class: "Decidim::SecureElections::CensusMember" do
      transient do
        skip_injection { false }
      end

      election { create(:vocdoni_election, skip_injection:) }

      name { Faker::Name.first_name }
      surname { Faker::Name.last_name }
      email { generate(:email) }
      sequence(:member_number) { |n| format("%06d", n) }
      weight { 1 }

      # Already in the Vocdoni memberbase. Only a published census has these,
      # and they are what maps an upstream `missingData` id back to a person.
      trait :pushed do
        vocdoni_member_id { Faker::Number.hexadecimal(digits: 24) }
      end

      trait :without_email do
        email { nil }
      end
    end
  end
end

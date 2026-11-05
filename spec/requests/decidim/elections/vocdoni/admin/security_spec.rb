# frozen_string_literal: true

require "spec_helper"

# The Security tab as an admin sees it (AC1), and who may not see or change
# it (AC2). The permission check is the controller's
# `enforce_permission_to(:update, :census, election:)`, unchanged by the
# redesign; these examples are what proves it still holds.
module Decidim
  module Elections
    module Vocdoni
      describe "Admin Security tab" do
        let(:organization) { component.organization }
        let(:component) { create(:elections_component) }
        let!(:election) { create(:election, :with_token_csv_census, component:) }
        let(:headers) { { "HOST" => organization.host } }
        let(:security_path) { Decidim::EngineRouter.admin_proxy(component).election_security_path(election) }
        let(:html) { response.parsed_body }

        def sidecar
          Vocdoni::Process.find_by(decidim_election_id: election.id)
        end

        context "when an admin opens the tab" do
          let(:admin) { create(:user, :admin, :confirmed, organization:) }

          before do
            login_as admin, scope: :user
            get security_path, headers:
          end

          it "renders everything inside one card under a disclosure header" do
            expect(response).to have_http_status(:ok)
            expect(html.css(".vocdoni-security__card").size).to eq(1)

            summary = html.at_css(".vocdoni-security__card details[open] > summary")
            expect(summary).to be_present
            expect(summary.text).to include("How do you want to run this vote?")
            expect(html.at_css("h1.item_show__header-title").text.strip).to eq("Edit election")
          end

          it "renders the two option cards with plain points and a footer band" do
            cards = html.css(".vocdoni-security__card [data-security-choice-card]")

            expect(cards.map { |card| card["data-security-choice-card"] }).to eq(%w(simple secure))
            cards.each do |card|
              expect(card.css("ul.list-disc > li").size).to eq(4)
              expect(card.css("ul.list-disc svg")).to be_empty
              expect(card.at_css(".vocdoni-choice__footer").text).to include("Best for:")
            end
          end

          it "keeps the radios labelled by the title and described by the card" do
            secure = html.at_css("#security_choice_secure")
            simple = html.at_css("#security_choice_simple")

            expect(secure["name"]).to eq("security[enable_vocdoni]")
            expect(secure["value"]).to eq("true")
            expect(simple["value"]).to eq("false")
            expect(secure["aria-describedby"]).to eq("security-choice-badge security-choice-secure-description")
            expect(html.at_css("label[for='security_choice_secure']").text.strip).to eq("Secret, verifiable vote")
          end

          it "puts the Recommended pill on the secure card and the Good to know row after the cards" do
            badge = html.at_css("[data-security-choice-card='secure'] > #security-choice-badge")

            expect(badge.text.strip).to eq("Recommended for binding decisions")
            expect(badge["class"]).not_to include("label")
            expect(html.at_css("#js-security-choice [data-security-good-to-know]").text).to include("Good to know:")
          end

          it "renders the one-time code block hidden and disabled for a simple vote" do
            block = html.at_css(".vocdoni-security__card fieldset#js-security-two-factor")

            expect(block).to be_present
            expect(block.has_attribute?("hidden")).to be(true)
            expect(block.has_attribute?("disabled")).to be(true)
            expect(block.at_css("#security_email")).to be_present
            expect(block.at_css("#security_sms")).to be_present
          end

          it "no longer renders the removed sections" do
            expect(response.body).not_to include("vocdoni-why")
            expect(response.body).not_to include("Why it matters")
            expect(html.at_css("#js-security-summary")).to be_nil
          end

          context "when the election has opted in to the secret vote" do
            let!(:election) do
              create(:election, :with_token_csv_census, component:).tap do |record|
                create(:vocdoni_process, election: record)
              end
            end

            it "renders the one-time code block visible and enabled" do
              block = html.at_css("fieldset#js-security-two-factor")

              expect(block.has_attribute?("hidden")).to be(false)
              expect(block.has_attribute?("disabled")).to be(false)
              expect(html.at_css("[data-security-choice-card='secure']")["class"]).to include("is-selected")
            end
          end
        end

        context "when a participant who is not an admin opens the tab" do
          let(:participant) { create(:user, :confirmed, organization:) }

          before { login_as participant, scope: :user }

          # Decidim's admin routes only match for admins, so the tab does not
          # exist for anybody else.
          it "is refused" do
            get(security_path, headers:)

            expect(response).to have_http_status(:not_found)
            expect(response.body).not_to include("vocdoni-security__card")
          end

          it "cannot opt the election in" do
            put(security_path, params: { security: { enable_vocdoni: "true", email: "1" } }, headers:)

            expect(response).to have_http_status(:not_found)
            expect(sidecar).to be_nil
          end
        end

        context "when an anonymous visitor opens the tab" do
          it "is sent to sign in" do
            get(security_path, headers:)

            expect(response).to have_http_status(:found)
            expect(response.location).to include("/users/sign_in")
          end

          it "cannot opt the election in" do
            put(security_path, params: { security: { enable_vocdoni: "true" } }, headers:)

            expect(response).to have_http_status(:found)
            expect(sidecar).to be_nil
          end
        end
      end
    end
  end
end

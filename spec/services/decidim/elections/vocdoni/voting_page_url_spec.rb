# frozen_string_literal: true

require "spec_helper"

module Decidim
  module Elections
    module Vocdoni
    describe VotingPageUrl do
      let(:staging) { "https://saas-api-stg.vocdoni.net" }
      let(:process_id) { "6a6899181400d83458fde280" }
      let(:exit_path) { "/en/processes/petiquipeti2/f/61/elections/20" }

      # The exact values the voting page's JavaScript decoder is tested against
      # (`app/packs/src/decidim/elections/vocdoni/voter/link_code.test.js`). They are the
      # only thing tying the two implementations together: change the layout on
      # one side and one of the two suites fails.
      describe "the wire format" do
        it "writes what the voting page reads" do
          expect(described_class.encode(api_url: staging, process_id:))
            .to eq("EAJqaJkYFADYNFj94oA")
          expect(described_class.encode(api_url: staging, process_id:, locale: "en"))
            .to eq("EgJqaJkYFADYNFj94oACZW4")
          expect(described_class.encode(api_url: staging, process_id:, locale: "en", exit_path:))
            .to eq("FgJqaJkYFADYNFj94oACZW4vZW4vcHJvY2Vzc2VzL3BldGlxdWlwZXRpMi9mLzYxL2VsZWN0aW9ucy8yMA")
        end

        # A process id is 12 bytes and a known API base is one, so a link that
        # needs nothing else is 14 bytes: 19 characters, against the 105 the
        # spelled-out form took for the same thing.
        it "spends 19 characters on the shortest link there is" do
          expect(described_class.encode(api_url: staging, process_id:).length).to eq(19)
        end

        it "is url-safe and unpadded, so it never needs escaping" do
          value = described_class.encode(api_url: staging, process_id:, exit_path:)

          expect(value).to match(/\A[A-Za-z0-9_-]+\z/)
          expect(CGI.escape(value)).to eq(value)
        end
      end

      describe ".encode" do
        it "round-trips every field" do
          value = described_class.encode(api_url: staging, process_id:, locale: :ca, exit_path:)

          expect(described_class.decode(value)).to eq(
            api: staging, process: process_id, locale: "ca", exit: exit_path
          )
        end

        # Absent, not empty: an omitted field costs no bytes at all.
        it "leaves out a locale and an exit that were not given" do
          value = described_class.encode(api_url: staging, process_id:)

          expect(described_class.decode(value)).to eq(
            api: staging, process: process_id, locale: nil, exit: nil
          )
        end

        it "carries an API base that is not in the table inline" do
          api = "https://vocdoni.example.org/api"
          value = described_class.encode(api_url: api, process_id:)

          expect(described_class.decode(value)[:api]).to eq(api)
          # Inline costs the URL plus a length byte, which is the whole reason
          # the known hosts have a code.
          expect(value.length).to be > described_class.encode(api_url: staging, process_id:).length
        end

        it "normalizes a trailing slash so a configured base still matches the table" do
          expect(described_class.encode(api_url: "#{staging}/", process_id:))
            .to eq(described_class.encode(api_url: staging, process_id:))
        end

        it "refuses to pack something that is not a process id" do
          expect(described_class.encode(api_url: staging, process_id: "nope")).to be_nil
          expect(described_class.encode(api_url: staging, process_id: nil)).to be_nil
          expect(described_class.encode(api_url: "", process_id:)).to be_nil
        end
      end

      # `decode` exists to make the point that this is an abbreviation and not a
      # secret. It is as strict as the JavaScript decoder, so that a value one
      # accepts is a value the other accepts.
      describe ".decode" do
        it "refuses a truncated, hostile or empty value without raising" do
          full = described_class.encode(api_url: staging, process_id:, locale: "en", exit_path:)

          [full[0..5], full[0..12], "not base64!", "../../etc/passwd", "", nil, "%%%"].each do |value|
            expect(described_class.decode(value)).to be_nil
          end
        end

        it "refuses a version, a flag or an API host code it does not know" do
          [[0x20, 2], [0x18, 2], [0x10, 0xff]].each do |header, api|
            packed = Base64.urlsafe_encode64(([header, api] + ([0x11] * 12)).pack("C*"), padding: false)

            expect(described_class.decode(packed)).to be_nil
          end
        end

        it "refuses trailing bytes nothing accounts for" do
          packed = Base64.urlsafe_encode64(([0x10, 2] + ([0x11] * 14)).pack("C*"), padding: false)

          expect(described_class.decode(packed)).to be_nil
        end
      end

      describe ".build" do
        let(:organization) { create(:organization) }
        let(:participatory_space) { create(:participatory_process, organization:) }
        let(:component) { create(:vocdoni_component, participatory_space:) }
        let(:election) { create(:vocdoni_election, :on_chain, component:) }

        it "points at the static page with one opaque parameter" do
          url = described_class.build(election, locale: "en")

          expect(url).to start_with("#{Decidim::Elections::Vocdoni::Engine::VOTE_PATH}?v=")
          expect(URI.parse(url).query).to match(/\Av=[A-Za-z0-9_-]+\z/)
        end

        it "carries the election's process and nothing about the voter" do
          fields = described_class.decode(URI.parse(described_class.build(election, locale: "en")).query.delete_prefix("v="))

          expect(fields[:process]).to eq(election.vocdoni_process_id)
          expect(fields[:api]).to eq(Decidim::Elections::Vocdoni.api_url)
          expect(fields[:exit]).to be_nil
        end

        it "has nothing to link to before the election is on chain" do
          draft = create(:vocdoni_election, :published, :ready_to_publish, component:)

          expect(described_class.build(draft)).to be_nil
        end

        it "has nowhere to send the browser without an API URL" do
          allow(Decidim::Elections::Vocdoni).to receive(:api_url).and_return(nil)

          expect(described_class.build(election)).to be_nil
        end
      end
    end
  end
end
end

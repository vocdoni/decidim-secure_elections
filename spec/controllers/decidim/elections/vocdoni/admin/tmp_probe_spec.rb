require "spec_helper"
require "decidim/elections/test/factories"

module Decidim
  module Elections
    module Vocdoni
      module Admin
        describe CensusFileController do
          render_views
          let(:component) { create(:elections_component) }
          let(:organization) { component.organization }
          let(:election) { create(:election, component:) }
          let(:current_user) { create(:user, :admin, :confirmed, organization:) }
          let(:content) do
            <<~CSV
              name,memberNumber
              Rosalind,000123
            CSV
          end
          let(:blob) do
            ActiveStorage::Blob.create_and_upload!(io: StringIO.new(content), filename: "people.csv", content_type: "text/csv")
          end

          before do
            request.env["decidim.current_organization"] = organization
            request.env["decidim.current_participatory_space"] = component.participatory_space
            request.env["decidim.current_component"] = component
            sign_in current_user
          end

          it "debug body" do
            get :new, params: { election_id: election.id, blob: blob.signed_id }
            File.write("/private/tmp/claude-501/-Users-ferran-Repos-decidim-vocdoni/12b5c660-9ec3-4ad4-abc1-ceed81922ff9/scratchpad/body.html", response.body)
          end
        end
      end
    end
  end
end

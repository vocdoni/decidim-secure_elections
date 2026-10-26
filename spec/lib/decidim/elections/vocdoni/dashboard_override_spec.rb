# frozen_string_literal: true

require "spec_helper"
require "digest"

# The Dashboard card needs one line in upstream's dashboard, which has no view
# hook, so the module ships a copy of that file (see its header) and the engine
# prepends its directory to `Decidim::Elections::Admin::ElectionsController`
# only. These examples keep the copy honest: any upstream change to the file
# fails here until the copy is re-synced.
module Decidim
  module Elections
    module Vocdoni
      describe "Dashboard view override" do
        # SHA-256 of decidim-elections/app/views/decidim/elections/admin/elections/dashboard.html.erb
        # at decidim/decidim 4c4d062fb9db171daac7fdad05d3bc5154ee15b2.
        let(:pinned_digest) { "7353b4ce482a28f4af761398d96cb3af4a8c93efaf0412454fb3d1e7b7927f27" }
        let(:relative_path) { "decidim/elections/admin/elections/dashboard.html.erb" }
        let(:overrides) { Engine.root.join("app/views/overrides") }
        let(:upstream_path) { Decidim::Elections::Engine.root.join("app/views", relative_path) }
        let(:copy_path) { overrides.join(relative_path) }
        let(:added_line) { %(    <%= render partial: "decidim/elections/vocdoni/admin/dashboard/security" %>\n) }

        let(:copy_lines) { copy_path.readlines }
        let(:header_end) { copy_lines.index("%>\n") }
        let(:copy_body) { copy_lines.drop(header_end + 1) }

        it "is synced with the installed upstream dashboard" do
          digest = Digest::SHA256.file(upstream_path).hexdigest
          hint = "#{upstream_path} changed upstream: re-copy it into #{copy_path}, re-add the two render lines, " \
                 "and update the pinned commit (file header) and digest (this spec)"

          expect(digest).to eq(pinned_digest), hint
        end

        it "opens with a header naming the upstream file and the pinned commit" do
          header = copy_lines.take(header_end + 1).join

          expect(copy_lines.first).to eq("<%#\n")
          expect(header).to include("decidim-elections/app/views/#{relative_path}")
          expect(header).to include("4c4d062fb9db171daac7fdad05d3bc5154ee15b2")
        end

        it "differs from upstream only by the two added render lines" do
          expect(copy_body.count(added_line)).to eq(2)
          expect(copy_body - [added_line]).to eq(upstream_path.readlines)
        end

        it "adds the card after Results when published and before Main when not" do
          expect(copy_body[copy_body.index(added_line) - 1]).to include("admin/dashboard/results")
          expect(copy_body[copy_body.rindex(added_line) + 1]).to include("admin/dashboard/main")
        end

        it "shadows no other upstream view" do
          files = Dir.glob("**/*", base: overrides).select { |path| overrides.join(path).file? }

          expect(files).to eq([relative_path])
        end

        it "is on the view path of the elections admin controller only" do
          expect(Decidim::Elections::Admin::ElectionsController.view_paths.map(&:to_s).first).to eq(overrides.to_s)
          expect(Decidim::Elections::Admin::ApplicationController.view_paths.map(&:to_s)).not_to include(overrides.to_s)
          expect(ActionController::Base.view_paths.map(&:to_s)).not_to include(overrides.to_s)
        end
      end
    end
  end
end

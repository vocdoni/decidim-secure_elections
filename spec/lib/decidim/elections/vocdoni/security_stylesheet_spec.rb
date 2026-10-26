# frozen_string_literal: true

require "spec_helper"

# Every colour on the Security tab and the Dashboard card is a Design System
# token from `_tokens.scss` (a CSS custom property from decidim/decidim#17722
# with the Figma value as fallback), never a legacy Tailwind colour utility
# or a raw value. See docs/design/security-tab/README.md.
module Decidim
  module Elections
    module Vocdoni
      describe "Security tab stylesheet" do
        let(:directory) { Engine.root.join("app/packs/stylesheets/decidim/elections/vocdoni/admin") }
        let(:tokens) { directory.join("_tokens.scss").read(encoding: "UTF-8") }
        # Line comments carry the contrast notes and prose; only code counts.
        let(:code) { directory.join("security.scss").read(encoding: "UTF-8").gsub(%r{//[^\n]*}, "") }

        it "uses no Tailwind colour utility" do
          expect(code).not_to match(/(?<![\w$-])(?:text|bg|border|fill|stroke|outline|accent|ring|decoration)-(?:gray|background|secondary|primary|tertiary|black|white|success|alert|warning|neutral)\b/)
        end

        it "writes no raw colour" do
          expect(code).not_to match(/#\h{3,8}\b|\b(?:rgba?|hsla?)\(/)
        end

        it "takes every colour declaration from a token" do
          declarations = code.scan(/^\s*(color|background(?:-color)?|border(?:-(?:top|right|bottom|left))?(?:-color)?|fill|stroke|outline-color|accent-color|box-shadow):\s*([^;]+);/)

          expect(declarations).not_to be_empty
          declarations.each do |property, value|
            expect(value).to match(/\$color-[a-z-]+/), "#{property}: #{value} does not use a colour token"
          end
        end

        it "only uses tokens that _tokens.scss defines" do
          defined = tokens.scan(/^\$([a-z0-9-]+):/).flatten
          used = code.scan(/\$([a-z0-9-]+)/).flatten.uniq

          expect(used - defined).to be_empty
        end

        it "defines every colour token as a Design System variable with the Figma value as fallback" do
          definitions = tokens.scan(/^\$(color-[a-z-]+):\s*([^;]+);/)

          expect(definitions).not_to be_empty
          definitions.each do |name, value|
            expect(value).to match(/\Avar\(--(?:color-color-[a-z-]+|secondary), #\h{6}\)\z/), "$#{name}: #{value}"
          end
        end
      end
    end
  end
end

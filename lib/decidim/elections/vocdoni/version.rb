# frozen_string_literal: true

module Decidim
  # Version metadata for the decidim-elections-vocdoni module.
  module Elections
    module Vocdoni
    VERSION = "0.1.0"

    # The Decidim releases this module is built and tested against.
    #
    # The lower bound is the `.dev` prerelease on purpose: RubyGems orders
    # `0.33.0.dev` *below* `0.33.0`, so a plain `>= 0.33.0` refuses to resolve
    # against a checkout of the Decidim development branch.
    DECIDIM_COMPAT_VERSION = [">= 0.33.0.dev", "< 0.34"].freeze

    def self.version
      VERSION
    end
  end
end
end

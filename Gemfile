# frozen_string_literal: true

source "https://rubygems.org"

ruby RUBY_VERSION

gemspec

# Where Decidim comes from in this development environment:
#
#   DECIDIM_PATH=/path/to/decidim   a local checkout, for developing the module
#                                   and Decidim together
#   otherwise                       the branch Decidim 0.33 is distributed from,
#                                   overridable with DECIDIM_REF
decidim_path = ENV.fetch("DECIDIM_PATH", nil)
decidim_ref = ENV.fetch("DECIDIM_REF", "develop")

# rubocop:disable Bundler/DuplicatedGem -- the two branches are exclusive
if decidim_path
  gem "decidim", path: decidim_path
  gem "decidim-dev", path: decidim_path
  gem "decidim-initiatives", path: decidim_path
  gem "decidim-participatory_processes", path: decidim_path
else
  git "https://github.com/decidim/decidim", branch: decidim_ref do
    gem "decidim"
    gem "decidim-dev"
    # `rake test_app` (from decidim-dev) generates a dummy_signature_handler
    # that inherits from Decidim::Initiatives::SignatureHandler, so the
    # dummy app fails to boot without the initiatives gem loaded.
    gem "decidim-initiatives"
    gem "decidim-participatory_processes"
  end
end
# rubocop:enable Bundler/DuplicatedGem

group :development, :test do
  gem "bootsnap", "~> 1.24"
  gem "puma", ">= 6.3.1"
  gem "webmock", "~> 3.23"
end

group :development do
  gem "letter_opener_web", "~> 3.0"
  gem "listen", "~> 3.10"
  gem "web-console", "~> 4.3"
end

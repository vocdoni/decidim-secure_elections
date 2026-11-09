# frozen_string_literal: true

# Pins are append-only in the database (no DELETE, no TRUNCATE), so specs
# check the guard is in place and lift it only to clean up committed pins.
module CspPinsSpecHelpers
  def enabled_csp_pins_triggers
    ActiveRecord::Base.connection.select_values(<<~SQL.squish)
      SELECT tgname FROM pg_trigger
      WHERE tgrelid = 'decidim_vocdoni_csp_pins'::regclass AND NOT tgisinternal AND tgenabled <> 'D'
      ORDER BY tgname
    SQL
  end
end

# "with concurrency" for specs that commit pins. Its cleanup TRUNCATEs every
# non-empty table with CASCADE, which reaches the pins table through the FK
# chain and fires the no-truncate trigger. The pins guard is lifted for that
# cleanup only: the `after` hook declared here runs before the shared
# context's (RSpec runs `after` hooks in reverse order), and the `around`
# hook, which wraps all `after` hooks, restores the guard.
RSpec.shared_context "with concurrency and csp pins" do
  include_context "with concurrency"

  around do |example|
    example.run
  ensure
    ActiveRecord::Base.connection.execute("ALTER TABLE decidim_vocdoni_csp_pins ENABLE TRIGGER USER")
  end

  after do
    connection = ActiveRecord::Base.connection
    connection.execute("ALTER TABLE decidim_vocdoni_csp_pins DISABLE TRIGGER USER")
    connection.execute("DELETE FROM decidim_vocdoni_csp_pins")
  end
end

RSpec.configure do |config|
  config.include CspPinsSpecHelpers
end

# frozen_string_literal: true

namespace :decidim_secure_elections do
  desc "Create a managed Vocdoni organization and print the address to configure as VOCDONI_ORG_ADDRESS"
  task :create_organization, [:name] => :environment do |_t, args|
    organization_name = Decidim::Organization.first&.name
    organization_name = organization_name.values.first if organization_name.is_a?(Hash)
    name = args[:name].presence || organization_name.presence || "Decidim"

    abort "VOCDONI_API_URL and VOCDONI_API_KEY must be set before creating an organization." if Decidim::SecureElections.api_url.blank? || Decidim::SecureElections.api_key.blank?

    client = Decidim::SecureElections::ApiClient.new
    org = client.organizations.create_managed(name:, type: "association")

    puts ""
    puts "Created Vocdoni organization #{name.inspect}."
    puts ""
    puts "  VOCDONI_ORG_ADDRESS=#{org["address"]}"
    puts ""
    puts "Add that to your environment (or credentials) and restart the application."
  end

  desc "Show the current decidim-secure_elections configuration and check connectivity"
  task doctor: :environment do
    puts "api_url:      #{Decidim::SecureElections.api_url.presence || "(unset)"}"
    puts "api_key:      #{Decidim::SecureElections.api_key.present? ? "set (#{Decidim::SecureElections.api_key[0, 8]}…)" : "(unset)"}"
    puts "org_address:  #{Decidim::SecureElections.org_address.presence || "(unset)"}"
    puts "explorer_url: #{Decidim::SecureElections.explorer_url}"
    puts "configured?:  #{Decidim::SecureElections.configured?}"

    # A worker that is not listening on `:vocdoni` silently drops publish and
    # sync jobs — the failure mode is invisible in the UI and looks like a
    # hung publish. Reported before connectivity because it produces the same
    # symptom and is cheaper to check.
    queue_status = check_vocdoni_queue
    puts "vocdoni queue: #{queue_status}"

    unless Decidim::SecureElections.configured?
      puts "\nNot fully configured — see .env.example."
      next
    end

    client = Decidim::SecureElections::ApiClient.new

    begin
      # Public, unauthenticated — proves the base URL is right.
      info = client.get("/info", auth: :none)
      puts "\nAPI reachable. chainId=#{info["chainId"]} goVersion=#{info["goVersion"]}"
    rescue StandardError => e
      puts "\nAPI unreachable: #{e.class}: #{e.message}"
      next
    end

    begin
      # Authenticated — proves the key works and is scoped to the configured org.
      groups = client.organizations.groups(Decidim::SecureElections.org_address)
      total = groups["groups"]&.sum { |g| g["membersCount"].to_i }
      puts "Credentials OK. #{groups["groups"]&.size.to_i} member group(s), #{total.to_i} member(s)."
    rescue StandardError => e
      puts "Credentials rejected: #{e.class}: #{e.message}"
    end
  end

  # Reports whether a Sidekiq worker is running that listens on the `vocdoni`
  # queue. Sidekiq is queried through its own API rather than by parsing
  # sidekiq.yml, because the answer that matters is what is *running*, not
  # what is written on disk.
  #
  # Falls back to a soft note when Sidekiq is not the adapter: other adapters
  # do not have the "queue must be listed to be consumed" pitfall this check
  # exists for, so silence beats a false positive.
  def check_vocdoni_queue
    return "(skipped — ActiveJob adapter is #{ActiveJob::Base.queue_adapter_name})" unless ActiveJob::Base.queue_adapter_name == "sidekiq"

    require "sidekiq/api"
    queues = Sidekiq::ProcessSet.new.flat_map { |process| process["queues"] }.uniq
    return "no Sidekiq processes are running — start the worker" if queues.empty?
    return "OK (running on #{queues.count { |q| q == "vocdoni" }} process(es))" if queues.include?("vocdoni")

    "MISSING — Sidekiq is running but no process listens on `vocdoni`. " \
      "Add `- [vocdoni, 3]` to config/sidekiq.yml and restart the worker, " \
      "or publish/sync jobs will queue forever."
  rescue StandardError => e
    "(check failed: #{e.class}: #{e.message})"
  end
end

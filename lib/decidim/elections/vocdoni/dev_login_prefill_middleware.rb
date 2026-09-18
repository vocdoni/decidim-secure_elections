# frozen_string_literal: true

require "json"

module Decidim
  module Elections
    module Vocdoni
      # Injects a small `<script>` on the Devise sign-in page that pre-fills
      # the email + password inputs with the seeded admin credentials pulled
      # from `DECIDIM_ADMIN_EMAIL` / `DECIDIM_ADMIN_PASSWORD` at boot.
      # Mirrors `try.decidim.org`, so an operator (or Claude) can drop into
      # the deploy without hunting for the password. Dev only — the engine
      # initializer only mounts this middleware when `Rails.env.development?`.
      class DevLoginPrefillMiddleware
          SIGN_IN_PATH_FRAGMENT = "/users/sign_in"

          def initialize(app)
            @app = app
            email = ENV["DECIDIM_ADMIN_EMAIL"] || "admin@example.org"
            password = ENV["DECIDIM_ADMIN_PASSWORD"] || "decidim123456789"
            @snippet = build_snippet(email, password)
          end

          def call(env)
            status, headers, response = @app.call(env)
            return [status, headers, response] unless inject?(env, headers)

            body = +""
            response.each { |chunk| body << chunk.to_s }
            response.close if response.respond_to?(:close)

            body.sub!("</body>", "#{@snippet}</body>") if body.include?("</body>")
            headers["Content-Length"] = body.bytesize.to_s if headers.key?("Content-Length")
            headers["content-length"] = body.bytesize.to_s if headers.key?("content-length")

            [status, headers, [body]]
          end

          private

          def build_snippet(email, password)
            <<~HTML.strip
              <script>(function(){
                var setValue=function(sel,val){
                  document.querySelectorAll(sel).forEach(function(el){
                    if(!el.value) el.value=val;
                  });
                };
                setValue('input[name="user[email]"]',#{email.to_json});
                setValue('input[name="user[password]"]',#{password.to_json});
              })();</script>
            HTML
          end

          def inject?(env, headers)
            return false unless env["PATH_INFO"].to_s.include?(SIGN_IN_PATH_FRAGMENT)

            content_type = headers["Content-Type"] || headers["content-type"] || ""
            content_type.include?("text/html")
          end
      end
    end
  end
end

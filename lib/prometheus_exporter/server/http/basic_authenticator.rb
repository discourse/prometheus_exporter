# frozen_string_literal: true
#
# This file contains logic derived from WEBrick HTTPAuth::BasicAuth and Htpasswd.
# Copyright (c) 2003 Internet Programming with Ruby writers. All rights reserved.
# Vendored from WEBrick commit 25b0e9206bf5991c6274893d53c428d23b3f2292.
# See VENDORED_WEBRICK_LICENSE.txt for the BSD-2-Clause terms.

module PrometheusExporter
  module Server
    module HTTP
      class BasicAuthenticator
        CRYPT_ENTRY = /\A([^:]+):([a-zA-Z0-9.\/]{13})\z/

        attr_reader :realm

        def initialize(path:, realm:, logger:)
          realm = realm.to_s
          raise ArgumentError, "realm contains control characters" if /[[:cntrl:]]/.match?(realm)

          @path = path
          @realm = realm
          @logger = logger
          @mtime = Time.at(0)
          @passwords = {}
          File.open(@path, "a").close unless File.exist?(@path)
          reload
        end

        def authenticate(authorization)
          match = /\ABasic\s+(.+)\z/i.match(authorization.to_s)
          return false unless match

          credentials = match[1].unpack1("m").split(":", 2)
          user = credentials[0]
          password = credentials[1] || ""
          return false if user.nil? || user.empty?

          reload
          encrypted = @passwords[user]
          encrypted && password.crypt(encrypted) == encrypted
        rescue ArgumentError
          false
        end

        def challenge
          escaped_realm = @realm.gsub(/["\\]/) { |character| "\\#{character}" }
          %(Basic realm="#{escaped_realm}")
        end

        private

        def reload
          mtime = File.mtime(@path)
          return if mtime <= @mtime

          passwords = {}
          File.foreach(@path, chomp: true) do |line|
            match = CRYPT_ENTRY.match(line)
            if !match
              if /:\$|:{SHA}/.match?(line)
                raise NotImplementedError, "MD5 and SHA1 .htpasswd entries are not supported"
              end
              raise StandardError, "bad .htpasswd file"
            end
            passwords[match[1]] = match[2]
          end
          @passwords = passwords
          @mtime = mtime
        rescue Errno::ENOENT => e
          @logger.error("Unable to read htpasswd file #{@path}: #{e.message}")
          raise
        end
      end
    end
  end
end

require 'net/http'
require 'json'

module Grr
  module Helper
    CONSUL_URL = 'http://localhost:8500'.freeze

    # IP address of a service registered in Consul
    def grr_service_ip(service, fallback = nil)
      uri = URI("#{CONSUL_URL}/v1/catalog/service/#{service}")
      body = Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 3) do |http|
        http.get(uri.request_uri).body
      end
      nodes = JSON.parse(body)
      ips = nodes.map { |n| n['ServiceAddress'].to_s.empty? ? n['Address'] : n['ServiceAddress'] }.compact.sort
      ips.first || fallback
    rescue StandardError => e
      Chef::Log.warn("grr: Unable to query Consul for #{service} (#{e.class}: #{e.message})")
      fallback
    end
  end
end

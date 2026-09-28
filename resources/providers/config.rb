# Cookbook:: grr
# Provider:: config

require 'securerandom'
require 'json'
require 'fileutils'
require 'tmpdir'

include Grr::Helper
include Chef::Mixin::ShellOut

CERTS_DATABAG_DIR = '/var/chef/data/data_bag_encrypted/certs'.freeze
CERTS_DATABAG_FILE = "#{CERTS_DATABAG_DIR}/grr.json".freeze

action :add do
  configure_mariadb
  configure_fleetspeak
  install_grr
  start_services
end

action :remove do
  drop_databases
  stop_services

  package 'grr' do
    action :remove
  end

  service 'mariadb' do
    action [:stop, :disable]
  end

  package %w(mariadb-server mariadb-connector-c-devel) do
    action :remove
  end

  config_dir = new_resource.config_dir

  directory config_dir do
    recursive true
    action :delete
  end

  delete_grr_certs
end

action :register do
  register_in_consul
end

action :deregister do
  deregister_from_consul
end

# ----------------
# Implementation
# ----------------
private

# ----------------------------------------------------------------
# GRR Certificates
# ----------------------------------------------------------------
def grr_certs
  return @grr_certs if @grr_certs

  existing = new_resource.grr_certs

  @grr_certs =
    if existing.nil? || existing.empty?
      Chef::Log.info('grr_config: no se encontró data bag certs/grr_conf, generando certificados nuevos')
      generate_grr_certs
    else
      Chef::Log.info('grr_config: usando certificados existentes del data bag certs/grr_conf')
      existing
    end
end

def generate_grr_certs
  hostname = new_resource.hostname
  dir = Dir.mktmpdir('grr_certs')

  begin
    shell_out!("openssl genrsa -out #{dir}/ca.key 2048")
    shell_out!(
      "openssl req -x509 -new -nodes -key #{dir}/ca.key -sha256 -days 3650 " \
      "-subj '/CN=grr_test/C=US' -out #{dir}/ca.crt"
    )

    shell_out!("openssl genrsa -out #{dir}/server.key 2048")
    shell_out!(
      "openssl req -new -key #{dir}/server.key -subj '/CN=#{hostname}' -out #{dir}/server.csr"
    )
    shell_out!(
      "openssl x509 -req -in #{dir}/server.csr -CA #{dir}/ca.crt -CAkey #{dir}/ca.key " \
      "-CAcreateserial -out #{dir}/server.crt -days 3650 -sha256"
    )

    shell_out!("openssl genrsa -out #{dir}/exec_signing.key 2048")
    shell_out!("openssl rsa -in #{dir}/exec_signing.key -pubout -out #{dir}/exec_signing.pub")

    certs = {
      'id'                             => 'grr_conf',
      'ca_certificate'                 => ::File.read("#{dir}/ca.crt"),
      'ca_key'                         => ::File.read("#{dir}/ca.key"),
      'server_certificate'             => ::File.read("#{dir}/server.crt"),
      'server_key'                     => ::File.read("#{dir}/server.key"),
      'executable_signing_public_key'  => ::File.read("#{dir}/exec_signing.pub"),
      'executable_signing_private_key' => ::File.read("#{dir}/exec_signing.key"),
      'csrf_secret_key'                => SecureRandom.base64(48),
    }

    persist_grr_certs(certs)
    certs
  ensure
    FileUtils.remove_entry(dir) if ::Dir.exist?(dir)
  end
end

def persist_grr_certs(certs)
  FileUtils.mkdir_p(CERTS_DATABAG_DIR)
  ::File.write(CERTS_DATABAG_FILE, JSON.pretty_generate(certs))
  ::File.chmod(0o600, CERTS_DATABAG_FILE)

  shell_out!(
    "knife data bag from file certs #{CERTS_DATABAG_FILE} " \
    '--secret-file /etc/chef/encrypted_data_bag_secret'
  )
ensure
  ::File.delete(CERTS_DATABAG_FILE) if ::File.exist?(CERTS_DATABAG_FILE)
end

def configure_mariadb
  package %w(mariadb-server mariadb-connector-c-devel) do
    action :install
  end

  max_allowed_packet = new_resource.max_allowed_packet
  grr_secrets = new_resource.grr_secrets
  grr_db_user = grr_secrets['grr_db_user'] unless grr_secrets.empty?
  grr_db_password = grr_secrets['grr_db_password'] unless grr_secrets.empty?
  grr_database = new_resource.grr_database
  fleetspeak_database = new_resource.fleetspeak_database
  fleetspeak_db_user = grr_secrets['fleetspeak_db_user'] unless grr_secrets.empty?
  fleetspeak_db_password = grr_secrets['fleetspeak_db_password'] unless grr_secrets.empty?
  log_bin_trust_function_creators = new_resource.log_bin_trust_function_creators

  template '/etc/my.cnf.d/grr.cnf' do
    source 'grr.cnf.erb'
    cookbook 'grr'
    owner 'root'
    group 'root'
    mode '0644'
    variables(max_allowed_packet: max_allowed_packet, log_bin_trust_function_creators: log_bin_trust_function_creators)
    notifies :restart, 'service[mariadb]', :delayed
  end

  service 'mariadb' do
    action [:enable, :start]
  end

  execute 'setup_mariadb_databases_and_user' do
    sensitive true
    command <<-EOH
      set -e
      mariadb -e "CREATE USER IF NOT EXISTS '#{grr_db_user}'@'localhost' IDENTIFIED BY '#{grr_db_password}';"
      mariadb -e "CREATE USER IF NOT EXISTS '#{fleetspeak_db_user}'@'localhost' IDENTIFIED BY '#{fleetspeak_db_password}';"
      mariadb -e "CREATE DATABASE IF NOT EXISTS #{grr_database} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
      mariadb -e "CREATE DATABASE IF NOT EXISTS #{fleetspeak_database} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
      mariadb -e "GRANT ALL PRIVILEGES ON #{grr_database}.* TO '#{grr_db_user}'@'localhost';"
      mariadb -e "GRANT ALL PRIVILEGES ON #{fleetspeak_database}.* TO '#{fleetspeak_db_user}'@'localhost';"
      mariadb -e "FLUSH PRIVILEGES;"
    EOH
    not_if "mariadb -sN -e \"SELECT User FROM mysql.user WHERE User='#{grr_db_user}'\" | grep -q #{grr_db_user} && mariadb -sN -e \"SELECT User FROM mysql.user WHERE User='#{fleetspeak_db_user}'\" | grep -q #{fleetspeak_db_user}"
  end

  execute 'secure_mariadb_installation' do
    sensitive true
    command <<-EOH
      set -e
      mariadb -e "DELETE FROM mysql.user WHERE User='';"
      mariadb -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
      mariadb -e "DROP DATABASE IF EXISTS test;"
      mariadb -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
      mariadb -e "FLUSH PRIVILEGES;"
    EOH
    not_if "mariadb -sN -e \"SELECT COUNT(*) FROM mysql.user WHERE User=''\" | grep -q '^0$'"
  end
end

def configure_fleetspeak
  fleetspeak_cert_dir = new_resource.fleetspeak_cert_dir
  fleetspeak_dir = new_resource.fleetspeak_dir
  hostname = new_resource.hostname
  grr_secrets = new_resource.grr_secrets
  fleetspeak_db_user = grr_secrets['fleetspeak_db_user'] unless grr_secrets.empty?
  fleetspeak_db_password = grr_secrets['fleetspeak_db_password'] unless grr_secrets.empty?
  mysql_host = new_resource.mysql_host
  mysql_port = new_resource.mysql_port
  fleetspeak_database = new_resource.fleetspeak_database
  fleetspeak_https_listen = new_resource.fleetspeak_https_listen
  fleetspeak_admin_listen = new_resource.fleetspeak_admin_listen
  fleetspeak_grr_listen = new_resource.fleetspeak_grr_listen

  directory fleetspeak_cert_dir do
    owner 'root'
    group 'root'
    mode '0750'
    recursive true
  end

  cert_file = "#{fleetspeak_cert_dir}/server.pem"
  key_file  = "#{fleetspeak_cert_dir}/server-key.pem"

  execute 'generate_fleetspeak_selfsigned_cert' do
    sensitive true
    command <<-EOH
      set -e
      openssl req -x509 -nodes -newkey rsa:4096 -days 3650 \
        -keyout #{key_file} \
        -out #{cert_file} \
        -subj "/CN=#{hostname}" \
        -addext "subjectAltName=DNS:#{hostname},IP:127.0.0.1"
      chmod 0640 #{key_file} #{cert_file}
      chown root:root #{key_file} #{cert_file}
    EOH
    not_if { ::File.exist?(cert_file) && ::File.exist?(key_file) }
  end

  directory fleetspeak_dir do
    owner 'root'
    group 'root'
    mode '0750'
    recursive true
  end

  template "#{fleetspeak_dir}/server.components.config" do
    source 'server.components.config.erb'
    cookbook 'grr'
    owner 'root'
    group 'root'
    mode '0640'
    sensitive true
    variables lazy {
      {
        mysql_dsn: "#{fleetspeak_db_user}:#{fleetspeak_db_password}" \
                   "@tcp(#{mysql_host}:#{mysql_port})/#{fleetspeak_database}",
        https_listen: fleetspeak_https_listen,
        admin_listen: fleetspeak_admin_listen,
        certificate_pem: ::IO.read(cert_file).gsub("\n", '\n'),
        key_pem: ::IO.read(key_file).gsub("\n", '\n'),
      }
    }
  end

  template "#{fleetspeak_dir}/server.services.config" do
    source 'server.services.config.erb'
    cookbook 'grr'
    owner 'root'
    group 'root'
    mode '0640'
    variables(grr_listen: fleetspeak_grr_listen)
    notifies :restart, 'service[grr-fleetspeak]', :delayed
  end
end

def install_grr
  package 'grr' do
    action :install
  end

  config_dir = new_resource.config_dir
  install_data_dir = new_resource.install_data_dir
  mysql_host = new_resource.mysql_host
  mysql_port = new_resource.mysql_port
  grr_database = new_resource.grr_database
  grr_secrets = new_resource.grr_secrets
  grr_db_user = grr_secrets['grr_db_user'] unless grr_secrets.empty?
  grr_db_password = grr_secrets['grr_db_password'] unless grr_secrets.empty?
  adminui_url = new_resource.adminui_url
  adminui_port = new_resource.adminui_port
  frontend_port = new_resource.frontend_port
  frontend_url = new_resource.frontend_url
  fleetspeak_grr_listen = new_resource.fleetspeak_grr_listen
  fleetspeak_admin_listen = new_resource.fleetspeak_admin_listen
  certs = grr_certs

  directory config_dir do
    owner 'root'
    group 'root'
    mode '0750'
    recursive true
  end

  template "#{install_data_dir}/etc/server.local.yaml" do
    source 'server.local.yaml.erb'
    cookbook 'grr'
    owner 'root'
    group 'root'
    mode '0640'
    sensitive true
    variables(
      mysql_host: mysql_host,
      mysql_port: mysql_port,
      mysql_db: grr_database,
      mysql_user: grr_db_user,
      mysql_password: grr_db_password,
      adminui_url: adminui_url,
      adminui_port: adminui_port,
      frontend_port: frontend_port,
      frontend_url: frontend_url,
      fleetspeak_grr_listen: fleetspeak_grr_listen,
      fleetspeak_admin_listen: fleetspeak_admin_listen,
      ca_certificate: certs['ca_certificate'],
      ca_key: certs['ca_key'],
      server_certificate: certs['server_certificate'],
      server_key: certs['server_key'],
      executable_signing_public_key: certs['executable_signing_public_key'],
      executable_signing_private_key: certs['executable_signing_private_key'],
      csrf_secret_key: certs['csrf_secret_key']
    )
    action :create
  end

  grr_secrets = new_resource.grr_secrets
  admin_username = grr_secrets['admin_username'] unless grr_secrets.empty?
  admin_password = grr_secrets['admin_password'] unless grr_secrets.empty?
  server_local_yaml = new_resource.server_local_yaml
  config_updater_bin = new_resource.config_updater_bin

  execute 'grr_add_admin_user' do
    sensitive true
    command <<-EOH
      #{config_updater_bin} --config=#{server_local_yaml} \
        add_user #{admin_username} \
        --password #{admin_password} \
        --admin True
    EOH
    not_if <<-EOH
      #{config_updater_bin} --config=#{server_local_yaml} \
        show_user --username #{admin_username} 2>/dev/null | grep -q '^Username: #{admin_username}$'
    EOH
  end
end

def start_services
  service 'grr-fleetspeak' do
    action [:enable, :start]
  end

  ruby_block 'wait_for_fleetspeak' do
    block { sleep 5 }
    action :run
  end

  service 'grr-adminui' do
    action [:enable, :start]
  end

  ruby_block 'wait_for_adminui_schema' do
    block { sleep 10 }
    action :run
  end

  %w(grr-frontend grr-worker).each do |svc|
    service svc do
      action [:enable, :start]
    end
  end
end

def stop_services
  %w(grr-fleetspeak grr-adminui grr-frontend grr-worker).each do |svc|
    service svc do
      action [:stop, :disable]
    end
  end
end

def drop_databases
  execute 'drop_grr_databases_and_users' do
    sensitive true
    command <<-EOH
      set -e
      mariadb -e "DROP DATABASE IF EXISTS #{new_resource.grr_database};"
      mariadb -e "DROP DATABASE IF EXISTS #{new_resource.fleetspeak_database};"
      mariadb -e "DROP USER IF EXISTS '#{new_resource.grr_db_user}'@'localhost';"
      mariadb -e "DROP USER IF EXISTS '#{new_resource.fleetspeak_db_user}'@'localhost';"
      mariadb -e "FLUSH PRIVILEGES;"
    EOH
    only_if 'command -v mariadb && systemctl is-active --quiet mariadb'
  end
end

def delete_grr_certs
  # Item local (el que escribe persist_grr_certs)
  file CERTS_DATABAG_FILE do
    action :delete
  end

  # Item en el Chef Server (solo si lo subiste con knife)
  execute 'delete_grr_conf_data_bag_item' do
    command 'knife data bag delete certs grr_conf -y'
    only_if 'knife data bag show certs grr_conf --secret-file /etc/chef/encrypted_data_bag_secret >/dev/null 2>&1'
    ignore_failure true
  end
end

# --- Consul ------------------------------------------------------------

def grr_consul_services
  adminui_port = new_resource.adminui_port
  frontend_port = new_resource.frontend_port
  fleetspeak_port = new_resource.fleetspeak_port

  [
    {
      key: 'adminui',
      id: "grr-adminui-#{node['hostname']}",
      name: 'grr-adminui',
      port: adminui_port,
    },
    {
      key: 'frontend',
      id: "grr-frontend-#{node['hostname']}",
      name: 'grr-frontend',
      port: frontend_port,
    },
    {
      key: 'fleetspeak',
      id: "grr-fleetspeak-#{node['hostname']}",
      name: 'grr-fleetspeak',
      port: fleetspeak_port,
    },
  ]
end

def register_in_consul
  begin
    grr_consul_services.each do |svc|
      next if node['grr'][svc[:key]]['registered']

      query = {}
      query['ID'] = svc[:id]
      query['Name'] = svc[:name]
      query['Address'] = node['ipaddress']
      query['Port'] = svc[:port]
      json_query = Chef::JSONCompat.to_json(query)

      execute "Register #{svc[:name]} in consul" do
        command "curl -X PUT http://localhost:8500/v1/agent/service/register -d '#{json_query}' &>/dev/null"
        action :nothing
      end.run_action(:run)

      node.default['grr'][svc[:key]]['registered'] = true
      Chef::Log.info("#{svc[:name]} service has been registered to consul")
    end
  rescue => e
    Chef::Log.error(e.message)
  end
end

def deregister_from_consul
  begin
    grr_consul_services.each do |svc|
      next unless node['grr'][svc[:key]]['registered']

      execute "Deregister #{svc[:name]} in consul" do
        command "curl -X PUT http://localhost:8500/v1/agent/service/deregister/#{svc[:id]} &>/dev/null"
        action :nothing
      end.run_action(:run)

      node.default['grr'][svc[:key]]['registered'] = false
      Chef::Log.info("#{svc[:name]} service has been deregistered from consul")
    end
  rescue => e
    Chef::Log.error(e.message)
  end
end

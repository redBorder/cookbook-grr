# Cookbook:: grr
# Provider:: config

require 'securerandom'
require 'json'
require 'fileutils'
require 'tmpdir'
require 'shellwords'

include Grr::Helper
include Chef::Mixin::ShellOut

DATABAGS_DIR = '/var/chef/data/data_bag_encrypted'.freeze
DATABAG_SECRET = '/etc/chef/encrypted_data_bag_secret'.freeze
# The installers and the deployment scripts are prepared on the GRR node (local staging dir inside
# config_dir) and uploaded to S3: s3://<s3_bucket>/grr/{installers/{linux,windows},deployments}/
GRR_S3_PREFIX = 'grr'.freeze

action :add do
  package 'grr' do
    action :upgrade
  end

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

  delete_grr_databags
end

action :register do
  register_in_consul
end

action :deregister do
  deregister_from_consul
end

private

# ----------------------------------------------------------------
# Data bags
# ----------------------------------------------------------------

# Returns the data bag item: reads (decrypts) it if it exists and generates it only if it
# really does not exist. The recipe does not pass any secret; everything lives here.

def load_or_create_databag_item(bag, id)
  if databag_item_exists?(bag, id)
    data = read_databag_item(bag, id)
    return data if data

    raise "grr_config: The data bag #{bag}/#{id} exists but could not be decrypted with #{DATABAG_SECRET}. " \
          'It will not be overwritten. If it is stale (e.g. encrypted with another secret), ' \
          "delete it with: knife data bag delete #{bag} #{id} -y"
  end

  Chef::Log.info("grr_config: The data bag #{bag}/#{id} was not found; generating it")
  data = yield.merge('id' => id)
  persist_databag_item(bag, id, data)
  data
end

# Reads and decrypts an item with knife. Returns a Hash, or nil if it cannot be read or
# decrypted (wrong secret, plain-text item, invalid JSON...).
def read_databag_item(bag, id)
  out = shell_out("knife data bag show #{bag} #{id} --secret-file #{DATABAG_SECRET} -F json")
  unless out.exitstatus.zero?
    Chef::Log.warn("grr_config: knife could not decrypt #{bag}/#{id}: #{out.stderr.to_s.strip}")
    return
  end

  json = out.stdout[/\{.*\}/m] # knife prints an "INFO: Using configuration..." line first
  data = json && JSON.parse(json)
  return unless data.is_a?(Hash)
  # Values still looking like {"encrypted_data": ...} were not decrypted
  return if data.values.any? { |v| v.is_a?(Hash) && v.key?('encrypted_data') }

  data
rescue JSON::ParserError => e
  Chef::Log.warn("grr_config: invalid JSON reading #{bag}/#{id}: #{e.message}")
  nil
end

def databag_item_exists?(bag, id)
  out = shell_out("knife data bag show #{bag} #{id}")
  return true if out.exitstatus.zero?
  return false if "#{out.stdout}#{out.stderr}" =~ /404|not found|could not be found|could not find/i

  raise "grr_config: no se pudo comprobar si existe el data bag #{bag}/#{id}: #{out.stderr.to_s.strip}"
end

def persist_databag_item(bag, id, data)
  dir = ::File.join(DATABAGS_DIR, bag)
  file = ::File.join(dir, "#{id}.json")

  FileUtils.mkdir_p(dir)
  ::File.write(file, JSON.pretty_generate(data), perm: 0o600)
  shell_out!("knife data bag from file #{bag} #{file} --secret-file #{DATABAG_SECRET}")
ensure
  ::File.delete(file) if file && ::File.exist?(file)
end

def delete_databag_item(bag, id)
  file ::File.join(DATABAGS_DIR, bag, "#{id}.json") do
    action :delete
  end

  execute "delete_data_bag_item_#{bag}_#{id}" do
    command "knife data bag delete #{bag} #{id} -y"
    only_if "knife data bag show #{bag} #{id} >/dev/null 2>&1"
    ignore_failure true
  end
end

# ---- certs/grr_conf -------------------------------------------------------

def grr_certs
  @grr_certs ||= load_or_create_databag_item('certs', 'grr_conf') { generate_grr_certs }
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

    {
      'ca_certificate'                 => ::File.read("#{dir}/ca.crt"),
      'ca_key'                         => ::File.read("#{dir}/ca.key"),
      'server_certificate'             => ::File.read("#{dir}/server.crt"),
      'server_key'                     => ::File.read("#{dir}/server.key"),
      'executable_signing_public_key'  => ::File.read("#{dir}/exec_signing.pub"),
      'executable_signing_private_key' => ::File.read("#{dir}/exec_signing.key"),
      'csrf_secret_key'                => SecureRandom.base64(48),
    }
  ensure
    FileUtils.remove_entry(dir) if ::Dir.exist?(dir)
  end
end

# ---- passwords/db_grr -----------------------------------------------------

def grr_passwords
  @grr_passwords ||= load_or_create_databag_item('passwords', 'db_grr') { generate_grr_passwords }
end

def generate_grr_passwords
  {
    'grr_db_user'            => 'grr',
    'grr_db_password'        => SecureRandom.alphanumeric(32),
    'fleetspeak_db_user'     => 'fleetspeak',
    'fleetspeak_db_password' => SecureRandom.alphanumeric(32),
    'admin_username'         => 'admin',
    'admin_password'         => SecureRandom.alphanumeric(32),
  }
end

def configure_mariadb
  package %w(mariadb-server mariadb-connector-c-devel) do
    action :install
  end

  max_allowed_packet = new_resource.max_allowed_packet
  grr_secrets = grr_passwords
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
  grr_secrets = grr_passwords
  fleetspeak_db_user = grr_secrets['fleetspeak_db_user'] unless grr_secrets.empty?
  fleetspeak_db_password = grr_secrets['fleetspeak_db_password'] unless grr_secrets.empty?
  mysql_host = new_resource.mysql_host
  mysql_port = new_resource.mysql_port
  fleetspeak_database = new_resource.fleetspeak_database
  fleetspeak_https_listen = new_resource.fleetspeak_https_listen
  fleetspeak_admin_listen = new_resource.fleetspeak_admin_listen
  fleetspeak_grr_listen = new_resource.fleetspeak_grr_listen
  fleetspeak_port = fleetspeak_https_listen.split(':').last

  directory fleetspeak_cert_dir do
    owner 'root'
    group 'root'
    mode '0750'
    recursive true
  end

  configurator_config = "#{fleetspeak_cert_dir}/configurator.config"
  ca_file      = "#{fleetspeak_cert_dir}/ca.pem"
  server_cert  = "#{fleetspeak_cert_dir}/server.pem"

  template configurator_config do
    source 'fleetspeak_configurator.config.erb'
    cookbook 'grr'
    owner 'root'
    group 'root'
    mode '0640'
    sensitive true
    variables(
      configuration_name: 'redborder',
      mysql_dsn: "#{fleetspeak_db_user}:#{fleetspeak_db_password}@tcp(#{mysql_host}:#{mysql_port})/#{fleetspeak_database}",
      https_listen: fleetspeak_https_listen,
      admin_listen: fleetspeak_admin_listen,
      public_host_port: "#{hostname}:#{fleetspeak_port}",
      cert_dir: fleetspeak_cert_dir
    )
  end

  execute 'run_fleetspeak_config' do
    command "/opt/grr/venv/fleetspeak-server-bin/usr/bin/fleetspeak-config -config #{configurator_config}"
    not_if { ::File.exist?(server_cert) && ::File.exist?(ca_file) }
  end

  directory fleetspeak_dir do
    owner 'root'
    group 'root'
    mode '0750'
    recursive true
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
  file '/etc/rpm/macros.grr' do
    content "%_unpackaged_files_terminate_build 0\n"
    owner 'root'
    group 'root'
    mode '0644'
  end

  config_dir = new_resource.config_dir
  install_data_dir = new_resource.install_data_dir
  mysql_host = new_resource.mysql_host
  mysql_port = new_resource.mysql_port
  grr_database = new_resource.grr_database
  grr_secrets = grr_passwords
  grr_db_user = grr_secrets['grr_db_user'] unless grr_secrets.empty?
  grr_db_password = grr_secrets['grr_db_password'] unless grr_secrets.empty?
  adminui_url = new_resource.adminui_url
  adminui_port = new_resource.adminui_port
  frontend_port = new_resource.frontend_port
  frontend_url = new_resource.frontend_url
  fleetspeak_grr_listen = new_resource.fleetspeak_grr_listen
  fleetspeak_admin_listen = new_resource.fleetspeak_admin_listen
  fleetspeak_cert_dir = new_resource.fleetspeak_cert_dir
  server_local_yaml = new_resource.server_local_yaml
  config_updater_bin = new_resource.config_updater_bin
  venv_bin_dir = ::File.dirname(config_updater_bin)
  venv_dir = ::File.dirname(venv_bin_dir)
  grr_server_yaml = "#{install_data_dir}/etc/grr-server.yaml"
  templates_dir = "#{venv_dir}/grr-response-templates/templates"
  installers_dir = "#{venv_dir}/executables/installers"
  cleanup_script = "#{venv_dir}/tmp_cleanup_signed_binaries.py"
  fleetspeak_client_config = "#{fleetspeak_cert_dir}/linux_client.config"
  fleetspeak_client_config_windows = "#{fleetspeak_cert_dir}/windows_client.config"
  client_templates_dir = "#{venv_dir}/client_templates"
  fix_script = "#{venv_dir}/grr_fix_installers.py"
  certs = grr_certs

  # Local staging tree, uploaded to S3 as is
  publish_dir            = "#{config_dir}/publish"
  publish_installers_dir = "#{publish_dir}/installers"
  publish_scripts_dir    = "#{publish_dir}/deployments"

  # S3 access
  s3_url      = "s3://#{new_resource.s3_bucket}/#{GRR_S3_PREFIX}"
  s3_base_cmd = s3_command
  s3_ready    = !s3_base_cmd.nil?
  s3_cmd      = s3_base_cmd || 's3cmd'
  s3_sync_cmd = "#{s3_cmd} sync --no-progress --delete-removed #{publish_dir}/ #{s3_url}/"

  # The IP address and name that clients use to connect to this GRR server. These are specified in
  # the deployment scripts as default values.
  grr_fleetspeak_hosts = Array(new_resource.grr_fleetspeak_hosts).compact

  deploy_server_name = (grr_fleetspeak_hosts.first || new_resource.hostname).to_s.gsub(/[^A-Za-z0-9.-]/, '')
  deploy_server_ip   = grr_service_ip('grr-fleetspeak', node['ipaddress']).to_s.gsub(/[^0-9A-Fa-f:.]/, '')

  directory publish_dir do
    owner 'root'
    group 'root'
    mode '0755'
    recursive true
  end

  directory publish_scripts_dir do
    owner 'root'
    group 'root'
    mode '0755'
    recursive true
  end

  %w(deploy_fedora.sh deploy_windows.ps1).each do |script|
    template "#{publish_scripts_dir}/#{script}" do
      source "#{script}.erb"
      cookbook 'grr'
      owner 'root'
      group 'root'
      mode '0755'
      variables(server_ip: deploy_server_ip, server_name: deploy_server_name)
      notifies :run, 'execute[grr_s3_sync]', :delayed
    end
  end

  %w(deploy_grr_client.sh deploy_grr_client.ps1
     deploy_fedora.sh.erb deploy_windows.ps1.erb).each do |old|
    file "#{publish_scripts_dir}/#{old}" do
      action :delete
    end
  end

  publish_cmd = <<-EOH
    set -e
    new=#{publish_installers_dir}.new
    rm -rf "$new"
    mkdir -p "$new/linux" "$new/windows"
    cp -f #{installers_dir}/*.rpm "$new/linux/"   2>/dev/null || true
    cp -f #{installers_dir}/*.msi "$new/windows/" 2>/dev/null || true
    chmod -R u=rwX,go=rX "$new"
    rm -rf #{publish_installers_dir}
    mv "$new" #{publish_installers_dir}
  EOH

  execute 'grr_publish_installers' do
    command publish_cmd
    notifies :run, 'execute[grr_s3_sync]', :immediately
    action :nothing
  end

  # Uploads the staging tree to S3
  execute 'grr_s3_sync' do
    command s3_sync_cmd
    timeout 600
    sensitive true
    only_if { s3_ready }
    action :nothing
  end

  directory config_dir do
    owner 'root'
    group 'root'
    mode '0750'
    recursive true
  end

  directory templates_dir do
    owner 'root'
    group 'root'
    mode '0750'
    recursive true
  end

  execute 'build_grr_client_template' do
    command "#{venv_bin_dir}/grr_client_build build " \
            "--output #{templates_dir} " \
            "--config #{grr_server_yaml} " \
            "--secondary_configs #{server_local_yaml}"
    not_if { !Dir.glob("#{templates_dir}/*.rpm.zip").empty? }
    timeout 1800
  end

  execute 'grr_install_windows_template' do
    command "cp -u #{client_templates_dir}/*.exe.zip #{templates_dir}/"
    only_if { !Dir.glob("#{client_templates_dir}/*.exe.zip").empty? }
    not_if do
      Dir.glob("#{client_templates_dir}/*.exe.zip").all? do |f|
        ::File.exist?("#{templates_dir}/#{::File.basename(f)}")
      end
    end
    notifies :run, 'execute[grr_repack_clients]', :delayed
  end

  file cleanup_script do
    content <<~PYTHON
      from grr_response_server import data_store
      from grr_response_server import server_startup

      server_startup.Init()
      ids = list(data_store.REL_DB.ReadIDsForAllSignedBinaries())
      for i in ids:
          data_store.REL_DB.DeleteSignedBinaryReferences(i)
      print(f"Deleted {len(ids)} signed binaries from REL_DB")
    PYTHON
    owner 'root'
    group 'root'
    mode '0640'
    action :nothing
  end

  cookbook_file fix_script do
    source 'grr_fix_installers.py'
    cookbook 'grr'
    owner 'root'
    group 'root'
    mode '0640'
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
      fleetspeak_client_config: fleetspeak_client_config,
      fleetspeak_client_config_windows: fleetspeak_client_config_windows,
      ca_certificate: certs['ca_certificate'],
      ca_key: certs['ca_key'],
      server_certificate: certs['server_certificate'],
      server_key: certs['server_key'],
      executable_signing_public_key: certs['executable_signing_public_key'],
      executable_signing_private_key: certs['executable_signing_private_key'],
      csrf_secret_key: certs['csrf_secret_key']
    )
    action :create
    notifies :create, "file[#{cleanup_script}]", :immediately
    notifies :run, 'execute[grr_clean_old_installers]', :immediately
    notifies :run, 'execute[grr_repack_clients]', :delayed
  end

  grr_secrets = grr_passwords
  admin_username = grr_secrets['admin_username'] unless grr_secrets.empty?
  admin_password = grr_secrets['admin_password'] unless grr_secrets.empty?

  execute 'grr_add_admin_user' do
    sensitive true
    command <<-EOH
      #{config_updater_bin} --config=#{grr_server_yaml} --secondary_configs=#{server_local_yaml} \
        add_user #{admin_username} \
        --password #{admin_password} \
        --admin True
    EOH
    not_if <<-EOH
      #{config_updater_bin} --config=#{grr_server_yaml} --secondary_configs=#{server_local_yaml} \
        show_user --username #{admin_username} 2>/dev/null | grep -q '^Username: #{admin_username}$'
    EOH
  end

  repack_cmd = "#{config_updater_bin} " \
               "--config=#{grr_server_yaml} " \
               "--secondary_configs=#{server_local_yaml} " \
               'repack_clients'

  execute 'grr_clean_old_installers' do
    command <<-EOH
      #{venv_bin_dir}/python #{cleanup_script} \
        --config=#{grr_server_yaml} \
        --secondary_configs=#{server_local_yaml}
      rm -f #{installers_dir}/*
    EOH
    action :nothing
  end

  execute 'grr_rename_windows_installers' do
    command <<-EOH
      set -e
      rm -f #{installers_dir}/dbg_*.exe
      for f in #{installers_dir}/*.exe; do
        [ -e "$f" ] || continue
        mv -f "$f" "${f%.exe}.msi"
      done
      APPLY=1 #{venv_bin_dir}/python #{fix_script} \
        --config=#{grr_server_yaml} \
        --secondary_configs=#{server_local_yaml}
    EOH
    notifies :run, 'execute[grr_publish_installers]', :immediately
    action :nothing
  end

  execute 'grr_repack_clients' do
    command repack_cmd
    action :nothing
    notifies :run, 'execute[grr_rename_windows_installers]', :immediately
  end

  execute 'grr_repack_clients_initial' do
    command repack_cmd
    not_if { Dir.glob("#{templates_dir}/*.zip").empty? || !Dir.glob("#{installers_dir}/*").empty? }
    notifies :run, 'execute[grr_rename_windows_installers]', :immediately
  end

  # There are installers but nothing staged yet (first run, or after a :remove)
  execute 'grr_publish_installers_initial' do
    command publish_cmd
    only_if { !Dir.glob("#{installers_dir}/*").empty? }
    not_if { !Dir.glob("#{publish_installers_dir}/*/*").empty? }
    notifies :run, 'execute[grr_s3_sync]', :immediately
  end

  # Reconciles S3 with the staging tree on every run: if something was deleted from S3 (grr/,
  # installers/ or deployments/) it is uploaded again. s3cmd sync only transfers what differs, so
  # when everything is in place it is just a listing. 
  execute 'grr_s3_sync_initial' do
    command s3_sync_cmd
    timeout 600
    sensitive true
    only_if do
      s3_ready &&
        !Dir.glob("#{publish_installers_dir}/*/*").empty? &&
        !Dir.glob("#{publish_scripts_dir}/*").empty?
    end
  end
end

# Base s3cmd command with host and credentials as options
def s3_command
  secrets = (new_resource.s3_secrets || {}).to_h
  pick = ->(*names) { names.map { |n| secrets[n] }.compact.map(&:to_s).reject(&:empty?).first }

  access_key = pick.call('s3_access_key_id')
  secret_key = pick.call('s3_secret_key_id')
  # s3_host may arrive as a String or as a list of hosts (the first one is used); quotes or spaces
  # coming with the value would break the host
  host = Array(new_resource.s3_host).flatten.compact.first.to_s.delete(%q("')).strip
  # HTTPS unless the host explicitly says http:// (s3.service sits behind nginx, which answers
  # HTTP with a 301 redirect to HTTPS)
  https = !host.start_with?('http://')
  host = host.sub(%r{\Ahttps?://}, '').chomp('/')

  if host.empty? || access_key.nil? || secret_key.nil?
    Chef::Log.warn('grr_config: S3 data (s3_host / s3_secrets) is not complete; installers are not uploaded')
    return
  end

  # -c /dev/null: do not read any s3cfg of root, everything comes from the options
  cmd = [
    's3cmd', '-c', '/dev/null',
    "--access_key=#{access_key}", "--secret_key=#{secret_key}",
    "--host=#{host}", "--host-bucket=#{host}",
    https ? '--ssl' : '--no-ssl'
  ]
  # internal service: its certificate is usually issued by the cluster's own CA
  cmd << '--no-check-certificate' if https
  cmd.shelljoin
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
  # Names of the DB users: from the data bag if it exists (it is NOT created here: we are
  # removing), otherwise the defaults used by generate_grr_passwords.
  secrets = read_databag_item('passwords', 'db_grr') || {}
  grr_db_user = secrets['grr_db_user'] || 'grr'
  fleetspeak_db_user = secrets['fleetspeak_db_user'] || 'fleetspeak'

  execute 'drop_grr_databases_and_users' do
    sensitive true
    command <<-EOH
      set -e
      mariadb -e "DROP DATABASE IF EXISTS #{new_resource.grr_database};"
      mariadb -e "DROP DATABASE IF EXISTS #{new_resource.fleetspeak_database};"
      mariadb -e "DROP USER IF EXISTS '#{grr_db_user}'@'localhost';"
      mariadb -e "DROP USER IF EXISTS '#{fleetspeak_db_user}'@'localhost';"
      mariadb -e "FLUSH PRIVILEGES;"
    EOH
    only_if 'command -v mariadb >/dev/null 2>&1 && systemctl is-active --quiet mariadb'
  end
end

def delete_grr_databags
  delete_databag_item('certs', 'grr_conf')
  delete_databag_item('passwords', 'db_grr')
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

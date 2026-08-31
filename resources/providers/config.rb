# Cookbook:: grr
# Provider:: config

include Grr::Helper

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

def configure_mariadb
  package %w(mariadb-server mariadb-connector-c-devel) do
    action :install
  end

  max_allowed_packet = new_resource.max_allowed_packet
  grr_db_user = new_resource.grr_db_user
  grr_db_password = new_resource.grr_db_password
  grr_database = new_resource.grr_database
  fleetspeak_database = new_resource.fleetspeak_database
  fleetspeak_db_user = new_resource.fleetspeak_db_user
  fleetspeak_db_password = new_resource.fleetspeak_db_password
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
  fleetspeak_db_user = new_resource.fleetspeak_db_user
  fleetspeak_db_password = new_resource.fleetspeak_db_password
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
  grr_db_user = new_resource.grr_db_user
  grr_db_password = new_resource.grr_db_password
  adminui_url = new_resource.adminui_url
  adminui_port = new_resource.adminui_port
  frontend_port = new_resource.frontend_port
  frontend_url = new_resource.frontend_url
  fleetspeak_grr_listen = new_resource.fleetspeak_grr_listen
  fleetspeak_admin_listen = new_resource.fleetspeak_admin_listen

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
      csrf_secret_key: SecureRandom.base64(48)
    )
    action :create
  end

  admin_password = new_resource.admin_password
  admin_username = new_resource.admin_username
  server_local_yaml = new_resource.server_local_yaml
  config_updater_bin = new_resource.config_updater_bin

  execute 'grr_add_admin_user' do
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
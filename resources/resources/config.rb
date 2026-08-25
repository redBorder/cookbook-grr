# Cookbook:: grr
# Resource:: config

actions :add, :remove, :register, :deregister
default_action :add

# --- MariaDB -----------------------------------------------------------
attribute :mysql_host,                      kind_of: String,  default: 'localhost'
attribute :mysql_port,                      kind_of: Integer, default: 3306
attribute :max_allowed_packet,              kind_of: String,  default: '64M'
attribute :log_bin_trust_function_creators, kind_of: Integer, default: 1

attribute :grr_database,                    kind_of: String,  default: 'grr'
attribute :grr_db_user,                     kind_of: String,  default: 'grr'
attribute :grr_db_password,                 kind_of: String,  default: 'redborder'

attribute :fleetspeak_database,             kind_of: String,  default: 'fleetspeak'
attribute :fleetspeak_db_user,              kind_of: String,  default: 'fleetspeak'
attribute :fleetspeak_db_password,          kind_of: String,  default: 'redborder'

# --- GRR / Fleetspeak ----------------------------------------------------
attribute :hostname,                        kind_of: String,  default: 'grr-server.redborder.cluster'
attribute :adminui_port,                    kind_of: Integer, default: 8002
attribute :adminui_url,                     kind_of: String,  default: 'https://grr-server.redborder.cluster:8002'
attribute :frontend_port,                   kind_of: Integer, default: 8084
attribute :frontend_url,                    kind_of: String,  default: 'https://grr-server.redborder.cluster:8084'
attribute :fleetspeak_port,                 kind_of: Integer, default: 8443

attribute :fleetspeak_https_listen,         kind_of: String, default: '0.0.0.0:8443'
attribute :fleetspeak_admin_listen,         kind_of: String, default: 'localhost:6061'
attribute :fleetspeak_grr_listen,           kind_of: String, default: 'localhost:1138'
attribute :fleetspeak_cert_dir,             kind_of: String, default: '/opt/grr/fleetspeak-server-bin/etc/fleetspeak-server'

attribute :admin_username,                  kind_of: String,  default: 'admin'
attribute :admin_password,                  kind_of: String,  default: 'redborder'

attribute :config_dir,                      kind_of: String,  default: '/opt/grr'
attribute :server_local_yaml,               kind_of: String,  default: '/opt/grr/install_data/etc/server.local.yaml'
attribute :fleetspeak_dir,                  kind_of: String,  default: '/opt/grr/fleetspeak-server-bin/etc/fleetspeak-server'
attribute :config_updater_bin,              kind_of: String,  default: '/opt/grr/bin/grr_config_updater'

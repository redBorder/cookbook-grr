# Flags
default['grr']['fleetspeak']['registered'] = false
default['grr']['adminui']['registered'] = false
default['grr']['frontend']['registered'] = false

default['grr']['fleetspeak']['port'] = 8443
default['grr']['adminui']['port'] = 8002
default['grr']['frontend']['port'] = 8084

# -----------------------------------------------------------------------
# MariaDB
# -----------------------------------------------------------------------
default['grr']['mysql']['host'] = '127.0.0.1'
default['grr']['mysql']['port'] = 3306
default['grr']['mysql']['max_allowed_packet'] = '64M'

default['grr']['mysql']['grr_database'] = 'grr'
default['grr']['mysql']['grr_user'] = 'grr'
default['grr']['mysql']['grr_password'] = 'redborder'

default['grr']['mysql']['fleetspeak_database'] = 'fleetspeak'
default['grr']['mysql']['fleetspeak_user'] = 'grr'
default['grr']['mysql']['fleetspeak_password'] = 'redborder'

# -----------------------------------------------------------------------
# URLs
# -----------------------------------------------------------------------
default['grr']['hostname'] = node['hostname']

default['grr']['adminui']['external_url'] = "http://#{default['grr']['hostname']}:8000"

default['grr']['frontend']['external_url'] = "http://#{default['grr']['hostname']}:8080"

# -----------------------------------------------------------------------
# Fleetspeak
# -----------------------------------------------------------------------
default['grr']['fleetspeak']['https_listen'] = 'localhost:9090'
default['grr']['fleetspeak']['admin_listen'] = 'localhost:9091'
default['grr']['fleetspeak']['grr_listen']   = 'localhost:1138'
default['grr']['fleetspeak']['cert_dir']     = '/opt/grr/venv/fleetspeak-server-bin/etc/fleetspeak-server'

# -----------------------------------------------------------------------
# GRR UI Admin User
# -----------------------------------------------------------------------
default['grr']['admin']['username'] = 'admin'
default['grr']['admin']['password'] = 'redborder'

# -----------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------
default['grr']['paths']['config_dir'] = '/etc/grr'
default['grr']['paths']['server_local_yaml'] = '/opt/grr/venv/install_data/etc/server.local.yaml'
default['grr']['paths']['fleetspeak_dir'] = '/opt/grr/venv/fleetspeak-server-bin/etc/fleetspeak-server'
default['grr']['paths']['config_updater_bin'] = '/opt/grr/venv/bin/grr_config_updater'

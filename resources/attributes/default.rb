# Flags
default['grr']['fleetspeak']['registered'] = false
default['grr']['adminui']['registered'] = false
default['grr']['frontend']['registered'] = false
default['grr']['worker']['registered'] = false

default['grr']['fleetspeak']['port'] = 8443
default['grr']['adminui']['port'] = 8002
default['grr']['frontend']['port'] = 8084

# -----------------------------------------------------------------------
# MariaDB / bases de datos
# -----------------------------------------------------------------------
default['grr']['mysql']['host']                = '127.0.0.1'
default['grr']['mysql']['port']                 = 3306
default['grr']['mysql']['max_allowed_packet']   = '64M'

default['grr']['mysql']['grr_database']         = 'grr'
default['grr']['mysql']['grr_user']             = 'grr'
default['grr']['mysql']['grr_password']         = 'redborder'

default['grr']['mysql']['fleetspeak_database']  = 'fleetspeak'
default['grr']['mysql']['fleetspeak_user']      = 'grr'      # puedes separarlo del usuario grr si prefieres
default['grr']['mysql']['fleetspeak_password']  = 'redborder'

# -----------------------------------------------------------------------
# Identidad del nodo / URLs públicas
# -----------------------------------------------------------------------
default['grr']['hostname'] = node['fqdn'] || node['hostname']

default['grr']['adminui']['external_url'] = "http://#{default['grr']['hostname']}:8000"

default['grr']['frontend']['external_url'] = "http://#{default['grr']['hostname']}:8080"

# -----------------------------------------------------------------------
# Fleetspeak (todo en el mismo nodo: https + admin + grr conviven)
# -----------------------------------------------------------------------
default['grr']['fleetspeak']['https_listen'] = 'localhost:9090'
default['grr']['fleetspeak']['admin_listen'] = 'localhost:9091'
default['grr']['fleetspeak']['grr_listen']   = 'localhost:1138'
default['grr']['fleetspeak']['cert_dir']     = '/etc/fleetspeak-server/certs'

# -----------------------------------------------------------------------
# Usuario admin de la UI de GRR
# -----------------------------------------------------------------------
default['grr']['admin']['username'] = 'admin'
default['grr']['admin']['password'] = 'redborder'

# -----------------------------------------------------------------------
# Rutas — AJUSTA ESTO a como las genere el RPM 'grr'
# -----------------------------------------------------------------------
default['grr']['paths']['config_dir']         = '/etc/grr'
default['grr']['paths']['server_local_yaml']  = '/etc/grr/server.local.yaml'
default['grr']['paths']['fleetspeak_dir']     = '/etc/fleetspeak-server'
default['grr']['paths']['config_updater_bin'] = '/usr/bin/grr_config_updater'

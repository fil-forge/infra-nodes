storage "raft" {
  path    = "/openbao/file"
  node_id = "filone-staging-eu-central-3"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = "true"
}

listener "unix" {
  address      = "/openbao/logs/api.sock"
  socket_mode  = "0600"
  socket_user  = "openbao"
  socket_group = "openbao"
}

seal "transit" {
  address    = "https://ssm.staging.fil-forge.com"
  mount_path = "transit"
  key_name   = "appliance-unseal-eu-central-3"
}

cluster_addr = "http://127.0.0.1:8201"
api_addr     = "http://127.0.0.1:8200"
disable_mlock = true
ui = false

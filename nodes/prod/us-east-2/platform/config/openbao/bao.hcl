storage "raft" {
  path    = "/openbao/file"
  node_id = "filone-prod-us-east-2"
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
  address    = "https://ssm.fil-forge.com"
  mount_path = "transit"
  key_name   = "appliance-unseal-us-east-2"
}

cluster_addr = "http://127.0.0.1:8201"
api_addr     = "http://127.0.0.1:8200"
disable_mlock = true
ui = false

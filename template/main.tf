terraform {
  required_providers {
    coder  = { source = "coder/coder" }
    docker = { source = "kreuzwerker/docker" }
  }
}

provider "docker" {}

variable "anthropic_api_key" {
  type      = string
  sensitive = true
  default   = ""
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

locals {
  # Four host ports per workspace, starting on a 10-port stride in 20000-59990.
  port_slot       = parseint(substr(replace(data.coder_workspace.me.id, "-", ""), 0, 3), 16) % 4000
  port_base       = 20000 + local.port_slot * 10
  frontend_port   = local.port_base
  bridge_port     = local.port_base + 1
  whisper_port    = local.port_base + 2
  vscode_port     = local.port_base + 3
  compose_project = "vc${substr(replace(data.coder_workspace.me.id, "-", ""), 0, 12)}"
  home_volume     = "coder-${data.coder_workspace.me.id}-home"
}

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"
  env = {
    ANTHROPIC_API_KEY  = var.anthropic_api_key
    ANTHROPIC_MODEL    = "claude-haiku-5-5"
    VC_FRONTEND_PORT   = tostring(local.frontend_port)
    VC_BRIDGE_PORT     = tostring(local.bridge_port)
    VC_WHISPER_PORT    = tostring(local.whisper_port)
    VC_VSCODE_PORT     = tostring(local.vscode_port)
    VC_COMPOSE_PROJECT = local.compose_project
    VC_HOME_VOLUME     = local.home_volume
  }
  metadata {
    display_name = "CPU"
    key          = "cpu"
    script       = "coder stat cpu"
    interval     = 10
    timeout      = 1
  }
  metadata {
    display_name = "RAM"
    key          = "ram"
    script       = "coder stat mem"
    interval     = 10
    timeout      = 1
  }
}

# Clones the repos, downloads the Whisper model, then starts Compose. The first build is slow.
resource "coder_script" "voicecoder_setup" {
  agent_id           = coder_agent.main.id
  display_name       = "VoiceCoder setup"
  icon               = "/icon/terminal.svg"
  run_on_start       = true
  start_blocks_login = true
  timeout            = 3600
  script             = file("${path.module}/setup.sh")
}

# Subdomain so /vscode/ and /ws stay on the frontend origin. Requires a wildcard access URL.
resource "coder_app" "frontend" {
  agent_id     = coder_agent.main.id
  slug         = "frontend"
  display_name = "VoiceCoder"
  icon         = "/icon/code.svg"
  url          = "http://host.docker.internal:${local.frontend_port}"
  subdomain    = true
  share        = "owner"
  healthcheck {
    url       = "http://host.docker.internal:${local.frontend_port}/"
    interval  = 15
    threshold = 120
  }
}

resource "docker_volume" "home" {
  name = local.home_volume
  lifecycle { ignore_changes = all }
}

resource "docker_container" "workspace" {
  count      = data.coder_workspace.me.start_count
  image      = "codercom/enterprise-base:ubuntu"
  name       = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  hostname   = data.coder_workspace.me.name
  entrypoint = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
  env        = ["CODER_AGENT_TOKEN=${coder_agent.main.token}"]
  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }
  volumes {
    container_path = "/var/run/docker.sock"
    host_path      = "/var/run/docker.sock"
  }
  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home.name
    read_only      = false
  }
}

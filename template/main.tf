terraform {
  required_providers {
    coder  = { source = "coder/coder" }
    docker = { source = "kreuzwerker/docker" }
  }
}

provider "docker" {}

# Shown on the workspace create/start form so each user can paste their own key.
# Ephemeral: not kept in workspace metadata between builds; re-enter on restart.
data "coder_parameter" "anthropic_api_key" {
  name         = "anthropic_api_key"
  display_name = "Anthropic API Key"
  description  = "Needed for the coding agent. Leave empty to only transcribe and clean."
  type         = "string"
  form_type    = "input"
  mutable      = true
  ephemeral    = true
  default      = ""
  order        = 1
}

# Optional. With a key the bridge reads each agent summary aloud.
data "coder_parameter" "elevenlabs_api_key" {
  name         = "elevenlabs_api_key"
  display_name = "ElevenLabs API Key"
  description  = "Reads the agent's summary aloud. Leave empty for no speech."
  type         = "string"
  form_type    = "input"
  mutable      = true
  ephemeral    = true
  default      = ""
  order        = 2
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
    ANTHROPIC_API_KEY  = data.coder_parameter.anthropic_api_key.value
    ANTHROPIC_MODEL    = "claude-haiku-5-5"
    ELEVENLABS_API_KEY = data.coder_parameter.elevenlabs_api_key.value
    BRIDGE_END_WORD    = "over"
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

# Syncs repos and kicks Compose in the background. Images are tagged
# voicecoder-*:latest and shared across workspaces, so only the first boot on
# a host pays for a full build. Script exits quickly so the agent stays up.
resource "coder_script" "voicecoder_setup" {
  agent_id           = coder_agent.main.id
  display_name       = "VoiceCoder setup"
  icon               = "/icon/terminal.svg"
  run_on_start       = true
  start_blocks_login = false
  timeout            = 600
  script             = file("${path.module}/setup.sh")
}

# Subdomain so /vscode/ and /ws stay on the frontend origin. Requires a wildcard access URL.
# The agent dials a proxy inside this container. Names like host.docker.internal and frontend
# resolve on Tailscale, where the published port is not listening.
resource "coder_app" "frontend" {
  agent_id     = coder_agent.main.id
  slug         = "frontend"
  display_name = "VoiceCoder"
  icon         = "/icon/code.svg"
  url          = "http://127.0.0.1:8088"
  subdomain    = true
  share        = "owner"
  healthcheck {
    url       = "http://127.0.0.1:8088/"
    interval  = 15
    threshold = 120
  }
}

# Home volume shared with Compose (agent + VS Code). Compose creates its own
# network (`${COMPOSE_PROJECT_NAME}_default`); we do not pre-create one here —
# unused docker_network resources were hanging provision on a busy Docker host.
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

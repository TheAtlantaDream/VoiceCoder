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

# Per workspace switch: "native" runs Whisper and the bridge inside the workspace (proven path).
# "compose" runs the VoiceCoder repo's docker-compose.yml (whisper, bridge, frontend) on the host Docker.
data "coder_parameter" "runtime" {
  name         = "runtime"
  display_name = "Service runtime"
  description  = "native = run inside the workspace. compose = run VoiceCoder docker-compose on the host Docker (one workspace at a time)."
  type         = "string"
  default      = "native"
  mutable      = true
  option {
    name  = "Native (inside workspace)"
    value = "native"
  }
  option {
    name  = "Docker Compose (host Docker)"
    value = "compose"
  }
}

locals {
  compose  = data.coder_parameter.runtime.value == "compose"
  svc_host = local.compose ? "host.docker.internal" : "localhost"
}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"
  env = {
    ANTHROPIC_API_KEY = var.anthropic_api_key
    VC_RUNTIME        = data.coder_parameter.runtime.value
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

# Installs tools, builds Whisper, starts services. Logs on the workspace page.
resource "coder_script" "voicecoder_setup" {
  agent_id     = coder_agent.main.id
  display_name = "VoiceCoder setup"
  icon         = "/icon/terminal.svg"
  run_on_start = true
  script       = file("${path.module}/setup.sh")
}

resource "coder_app" "bridge" {
  agent_id     = coder_agent.main.id
  slug         = "bridge"
  display_name = "Voice bridge"
  icon         = "/icon/widgets.svg"
  url          = "http://${local.svc_host}:8000/health"
  subdomain    = false
  share        = "owner"
}

resource "coder_app" "frontend" {
  count        = local.compose ? 1 : 0
  agent_id     = coder_agent.main.id
  slug         = "frontend"
  display_name = "Frontend"
  icon         = "/icon/widgets.svg"
  url          = "http://host.docker.internal:80"
  subdomain    = false
  share        = "owner"
}

module "code-server" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/code-server/coder"
  agent_id = coder_agent.main.id
  folder   = "/home/coder/project"
  settings = {
    "editor.fontSize"              = 22
    "terminal.integrated.fontSize" = 20
    "workbench.colorTheme"         = "Default High Contrast"
    "editor.accessibilitySupport"  = "on"
    "files.autoSave"               = "afterDelay"
  }
}

resource "docker_volume" "home" {
  name = "coder-${data.coder_workspace.me.id}-home"
  lifecycle { ignore_changes = all }
}

resource "docker_container" "workspace" {
  count    = data.coder_workspace.me.start_count
  image    = "codercom/enterprise-base:ubuntu"
  name     = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
  hostname = data.coder_workspace.me.name
  entrypoint = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
  env      = ["CODER_AGENT_TOKEN=${coder_agent.main.token}"]
  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }
  # compose mode only: give the workspace the host Docker so it can run docker compose
  dynamic "volumes" {
    for_each = local.compose ? [1] : []
    content {
      container_path = "/var/run/docker.sock"
      host_path      = "/var/run/docker.sock"
    }
  }
  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home.name
    read_only      = false
  }
}

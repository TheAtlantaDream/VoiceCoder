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

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"
  env = {
    ANTHROPIC_API_KEY = var.anthropic_api_key
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

resource "coder_app" "voicecoder" {
  agent_id     = coder_agent.main.id
  slug         = "voicecoder"
  display_name = "VoiceCoder"
  icon         = "/icon/widgets.svg"
  url          = "http://localhost:8090"
  subdomain    = false
  share        = "owner"
  healthcheck {
    url       = "http://localhost:8090"
    interval  = 10
    threshold = 30
  }
}

resource "coder_app" "bridge" {
  agent_id     = coder_agent.main.id
  slug         = "bridge"
  display_name = "Voice bridge"
  icon         = "/icon/widgets.svg"
  url          = "http://localhost:8000/health"
  subdomain    = false
  share        = "owner"
}

module "code-server" {
  count    = data.coder_workspace.me.start_count
  source   = "registry.coder.com/coder/code-server/coder"
  agent_id = coder_agent.main.id
  folder   = "/home/coder/beta-test-demo"
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
  volumes {
    container_path = "/home/coder"
    volume_name    = docker_volume.home.name
    read_only      = false
  }
}

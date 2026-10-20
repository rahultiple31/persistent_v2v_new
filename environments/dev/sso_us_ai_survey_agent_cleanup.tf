# Delete the retired agent stack and its published versions from Connect state.
# The Connect instance, assistant, and shared survey prompt remain configured.
removed {
  from = module.BTSGSD-SSO-US-AI-Survey-Agent

  lifecycle {
    destroy = true
  }
}

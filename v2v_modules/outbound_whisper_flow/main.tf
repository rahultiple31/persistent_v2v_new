module "flow" {
  source = "../connect_flow_resource"

  flow = merge(var.settings, {
    name        = "BTSGSD-V2V-US-OutboundWhisperFlow"
    type        = "OUTBOUND_WHISPER"
    description = "Imported flow: BTSGSD-V2V-US-OutboundWhisperFlow"
    content     = file("${path.module}/assets/BTSGSD-OutboundWhisperFlow.json")
  })
}

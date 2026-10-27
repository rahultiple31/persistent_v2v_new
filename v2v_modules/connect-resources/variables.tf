variable "instance_id" {
  description = "Target Amazon Connect instance ID (module.connect.instance_id)."
  type        = string
}

variable "instance_arn" {
  description = "Target Amazon Connect instance ARN (module.connect.instance_arn)."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for the names of the queues and routing profiles created by this module."
  type        = string
  default     = "BTSGSD-V2V"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]*$", var.name_prefix))
    error_message = "name_prefix must start with a letter or number and contain only letters, numbers, hyphens, or underscores."
  }
}

variable "connect_queue_queue_id" {
  description = "Main queue ID supplied by the connect-queue module."
  type        = string
}

variable "tags" {
  description = "Common tags applied to all resources."
  type        = map(string)
  default = {
    Org         = "AbbVie"
    Environment = "DEV-SSO"
  }
}

# --------------------------------------------------------------------------
# Queues
# --------------------------------------------------------------------------
variable "outbound_caller_id_number_id" {
  description = "Connect resource UUID of the claimed phone number used as the queues' outbound caller ID."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.outbound_caller_id_number_id))
    error_message = "outbound_caller_id_number_id must be the claimed Amazon Connect phone-number resource UUID, not the telephone number."
  }
}

variable "outbound_flow_id" {
  description = "Outbound whisper flow used by the queues (module.connect.outbound_whisper_flow_id)."
  type        = string

  validation {
    condition     = var.outbound_flow_id != null
    error_message = "outbound_flow_id is required; supply outbound_whisper_flow_content to the connect module so the flow is created."
  }
}

# --------------------------------------------------------------------------
# Security profile permissions (custom profiles only; Admin, Agent,
# CallCenterManager and QualityAnalyst are Connect defaults resolved as data)
# --------------------------------------------------------------------------
variable "client_realtime_metrix_permissions" {
  description = "Permissions for the 'Client Realtime Metrix' security profile."
  type        = list(string)
  default = [
    "AccessMetrics",
    "AccessMetrics.AgentActivityAudit.Access",
    "AccessMetrics.Dashboards.Access",
    "AccessMetrics.DashboardsWithMyData.View",
    "AccessMetrics.HistoricalMetrics.Access",
    "AccessMetrics.RealTimeMetrics.Access",
    "BasicAgentAccess",
    "Bots.View",
    "CustomMetrics.View",
    "CustomViews.Access",
    "CustomerProfiles.Create",
    "CustomerProfiles.Edit",
    "CustomerProfiles.View",
    "OutboundCallAccess",
    "Queues.View",
    "RoutingPolicies.View",
    "Wisdom.View",
  ]
}

variable "supervisor_permissions" {
  description = "Permissions for the 'Supervisor' security profile."
  type        = list(string)
  default = [
    "AccessMetrics",
    "AccessMetrics.AgentActivityAudit.Access",
    "AccessMetrics.Dashboards.Access",
    "AccessMetrics.DashboardsWithMyData.View",
    "AccessMetrics.HistoricalMetrics.Access",
    "AccessMetrics.RealTimeMetrics.Access",
    "AgentGrouping.Create",
    "AgentGrouping.Edit",
    "AgentGrouping.View",
    "AgentStates.View",
    "AgentTimeCard.View",
    "AudioDeviceSettings.Access",
    "BasicAgentAccess",
    "CallRecordings.Redacted.Access",
    "CallRecordings.Redacted.DownloadButton",
    "CallRecordings.Unredacted.Access",
    "CallRecordings.Unredacted.DownloadButton",
    "ConfigureContactAttributes.View",
    "ContactAttributes.View",
    "ContactLensCustomVocabulary.View",
    "ContactLensPostContactSummary.View",
    "ContactSearch.View",
    "ContactSearchWithCharacteristics.View",
    "ContactSearchWithKeywords.View",
    "ContactTranscripts.Redacted.Access",
    "ContactTranscripts.Unredacted.Access",
    "ContactTranscripts.Unredacted.DownloadButton",
    "ContentManagement.Create",
    "ContentManagement.Delete",
    "ContentManagement.Edit",
    "ContentManagement.View",
    "CustomMetrics.View",
    "CustomViews.Access",
    "CustomerProfiles.Create",
    "CustomerProfiles.Edit",
    "CustomerProfiles.View",
    "DataTables.Edit",
    "DataTables.View",
    "Evaluation.Create",
    "Evaluation.Delete",
    "Evaluation.Edit",
    "Evaluation.View",
    "EvaluationForms.Create",
    "EvaluationForms.Delete",
    "EvaluationForms.Edit",
    "EvaluationForms.View",
    "GraphTrends.View",
    "HoursOfOperation.Edit",
    "HoursOfOperation.View",
    "ManagerListenIn",
    "MetricsReports.Create",
    "MetricsReports.Delete",
    "MetricsReports.Edit",
    "MetricsReports.Publish",
    "MetricsReports.Schedule",
    "MetricsReports.View",
    "OutboundCallAccess",
    "PhoneNumbers.View",
    "Prompts.Edit",
    "Prompts.View",
    "QConnectAIPrompts.Edit",
    "QConnectAIPrompts.View",
    "Queues.Create",
    "Queues.Edit",
    "Queues.View",
    "ReportSchedules.Create",
    "ReportSchedules.Delete",
    "ReportSchedules.Edit",
    "ReportSchedules.View",
    "Rules.Create",
    "Rules.Edit",
    "Rules.View",
    "SecurityProfiles.View",
    "TransferContact.Enabled",
    "TransferDestinations.Create",
    "TransferDestinations.Delete",
    "TransferDestinations.Edit",
    "TransferDestinations.View",
    "Users.Create",
    "Users.Delete",
    "Users.Edit",
    "Users.EditPermission",
    "Users.View",
  ]
}

variable "agent_realtime_report_metric_permissions" {
  description = "Permissions for the 'Agent Realtime Report Metric' security profile."
  type        = list(string)
  default = [
    "AccessMetrics",
    "AccessMetrics.AgentActivityAudit.Access",
    "AccessMetrics.Dashboards.Access",
    "AccessMetrics.DashboardsWithMyData.View",
    "AccessMetrics.HistoricalMetrics.Access",
    "AccessMetrics.RealTimeMetrics.Access",
    "AgentStates.View",
    "AudioDeviceSettings.Access",
    "BasicAgentAccess",
    "ContactAttributes.View",
    "ContactLensCustomVocabulary.View",
    "ContactSearchWithCharacteristics.View",
    "ContactSearchWithKeywords.View",
    "CustomViews.Access",
    "CustomerProfiles.View",
    "GraphTrends.View",
    "OutboundCallAccess",
    "Queues.View",
    "ThemeDetection.View",
    "Users.View",
  ]
}

variable "agent_lead_access_permissions" {
  description = "Permissions for the 'Agent Lead Access' security profile."
  type        = list(string)
  default = [
    "AccessMetrics",
    "AccessMetrics.AgentActivityAudit.Access",
    "AccessMetrics.Dashboards.Access",
    "AccessMetrics.DashboardsWithMyData.View",
    "AccessMetrics.HistoricalMetrics.Access",
    "AccessMetrics.RealTimeMetrics.Access",
    "AudioDeviceSettings.Access",
    "BasicAgentAccess",
    "ContactAttributes.View",
    "ContactLensCustomVocabulary.View",
    "ContactLensPostContactSummary.View",
    "ContactSearch.View",
    "ContactSearchWithCharacteristics.View",
    "ContactSearchWithKeywords.View",
    "CustomerProfiles.View",
    "MetricsReports.View",
    "OutboundCallAccess",
    "Queues.View",
    "Rules.View",
    "Users.View",
  ]
}

variable "limited_access_agent_permissions" {
  description = "Permissions for the 'Limited access agent' security profile."
  type        = list(string)
  default = [
    "ContactFlows.View",
    "HoursOfOperation.View",
    "PredefinedAttributes.View",
    "Prompts.View",
    "QConnectAIAgents.View",
    "QConnectAIPrompts.View",
    "QConnectGuardrails.View",
    "Queues.View",
    "RoutingPolicies.View",
    "TaskTemplates.View",
    "TransferDestinations.View",
  ]
}


# --------------------------------------------------------------------------
# Prompts
# --------------------------------------------------------------------------
variable "default_prompt_names" {
  description = "Default prompts that Connect creates with every instance, resolved read-only."
  type        = list(string)
  default = [
    "Beep.wav",
    "Music_Pop_ThisAndThatIsLife_Inst.wav",
    "Music_Rock_EverywhereTheSunShines_Inst.wav",
    "Music_Jazz_MyTimetoFly_Inst.wav",
    "Music_Pop_ThrowYourselfInFrontOfIt_Inst.wav",
    "CustomerQueue.wav",
    "CustomerHold.wav",
  ]
}

variable "moh_30sec_prompt_s3_uri" {
  description = "S3 URI of the MOH_30SEC .wav file, e.g. s3://bucket/prompts/MOH_30SEC.wav. The prompt is created only when set."
  type        = string
  default     = null

  validation {
    condition     = var.moh_30sec_prompt_s3_uri == null || can(regex("^s3://[^/]+/.+\\.wav$", var.moh_30sec_prompt_s3_uri))
    error_message = "moh_30sec_prompt_s3_uri must be an s3:// URI pointing to a .wav file."
  }
}

# --------------------------------------------------------------------------
# Quick connects (user type; the phone help-desk quick connects are managed
# by the connect-queue module)
# --------------------------------------------------------------------------
variable "quick_connect_flow_id" {
  description = "Agent transfer flow used by the user quick connects (module.connect.agent_transfer_flow_id)."
  type        = string

  validation {
    condition     = var.quick_connect_flow_id != null
    error_message = "quick_connect_flow_id is required; supply agent_transfer_flow_content and customer_queue_flow_content to the connect module so the flow is created."
  }
}

variable "help_desk_quick_connect_ids" {
  description = "Help-desk quick connects created by the connect-queue module, attached to the main queues (values(module.connect_queue.quick_connect_ids))."
  type        = list(string)
}

variable "quick_connect_mahendra_username" {
  description = "Connect username backing the 'Mahendra Kumar' quick connect."
  type        = string
  default     = "mahendra.kumar@abbvie.com"
}

variable "quick_connect_smita_username" {
  description = "Connect username backing the 'Smita Kulkarni' quick connect."
  type        = string
  default     = "smita.kulkarni@abbvie.com"
}

variable "quick_connect_govind_username" {
  description = "Connect username backing the 'Govind Khandelwal' quick connect."
  type        = string
  default     = "govind.khandelwal@abbvie.com"
}

# --------------------------------------------------------------------------
# Users (the SAML admin user is managed by the connect module)
# routing_profile keys: basic, us_agent, latam_agent, us_latam_vm_blended
# --------------------------------------------------------------------------
variable "create_users" {
  description = "Whether to create Connect users. SAML usernames must match the IdP."
  type        = bool
  default     = true
}

variable "users" {
  description = "Connect users keyed by SAML username, with their security profile name and routing profile key."
  type = map(object({
    first_name       = string
    last_name        = string
    security_profile = string
    routing_profile  = string
  }))
  default = {
    "bharat.patchigolla@abbvie.com"      = { first_name = "test", last_name = "bharath", security_profile = "Agent", routing_profile = "basic" }
    "smita.kulkarni@abbvie.com"          = { first_name = "Smita", last_name = "Kulkarni", security_profile = "Admin", routing_profile = "us_latam_vm_blended" }
    "argha.kamaldey@abbvie.com"          = { first_name = "Argha", last_name = "Kamal Dey", security_profile = "Admin", routing_profile = "basic" }
    "vinay.kumarsingamsetti@abbvie.com"  = { first_name = "Vinaykumar", last_name = "Singamsetti", security_profile = "Admin", routing_profile = "us_latam_vm_blended" }
    "mahendra.kumar@abbvie.com"          = { first_name = "Mahendra", last_name = "Kumar", security_profile = "Admin", routing_profile = "us_latam_vm_blended" }
    "muneer.pallakkan@abbvie.com"        = { first_name = "Muneer", last_name = "Pallakkan", security_profile = "Admin", routing_profile = "us_latam_vm_blended" }
    "akashdeep.awasthi@abbvie.com"       = { first_name = "Akashdeep", last_name = "Awasthi", security_profile = "Admin", routing_profile = "basic" }
    "amitkumar.patel@abbvie.com"         = { first_name = "Amitkumar", last_name = "Patel", security_profile = "Admin", routing_profile = "basic" }
    "rohit.paranjape@abbvie.com"         = { first_name = "Rohit", last_name = "Paranjape", security_profile = "Agent", routing_profile = "basic" }
    "shwetha.chandavar@abbvie.com"       = { first_name = "Shwetha", last_name = "Chandavar", security_profile = "Admin", routing_profile = "basic" }
    "joel.delatorrecontreras@abbvie.com" = { first_name = "Joel", last_name = "delatorrecontreras", security_profile = "Admin", routing_profile = "basic" }
    "govind.khandelwal@abbvie.com"       = { first_name = "Govind", last_name = "Khandelwal", security_profile = "Admin", routing_profile = "us_latam_vm_blended" }
    "rahul.tiple@abbvie.com"             = { first_name = "Rahul", last_name = "Tiple", security_profile = "Admin", routing_profile = "basic" }
  }

  validation {
    condition = alltrue([
      for user in values(var.users) : contains(["basic", "us_agent", "latam_agent", "us_latam_vm_blended"], user.routing_profile)
    ])
    error_message = "Each user's routing_profile must be one of: basic, us_agent, latam_agent, us_latam_vm_blended."
  }
}

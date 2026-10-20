variable "main_ib_latam_queue_name" {
  description = "Existing LATAM queue in the Dev Connect instance."
  type        = string
  default     = "BTSGSD-DEV-SSO-LATAM-MAIN-QUEUE"
}

variable "main_ib_phone_lookup_function_name" {
  description = "Existing phone lookup Lambda used by the inbound flow."
  type        = string
  default     = "SNOW_Abbvie"
}


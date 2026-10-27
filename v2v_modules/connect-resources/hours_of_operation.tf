# Hours of operation for the migrated queues, matching the source
# BTSGSD-DEV-SSO-HoursOfOperation_EN_ES_PT (open 24 hours, every day).
locals {
  hours_of_operation_days = toset([
    "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY",
    "FRIDAY", "SATURDAY", "SUNDAY"
  ])
}

resource "aws_connect_hours_of_operation" "v2v" {
  instance_id = local.instance_id
  name        = local.hours_of_operation_name
  description = "V2V-Always Open Hours"
  time_zone   = "America/New_York"

  dynamic "config" {
    for_each = local.hours_of_operation_days
    content {
      day = config.value
      start_time {
        hours   = 0
        minutes = 0
      }
      end_time {
        hours   = 0
        minutes = 0
      }
    }
  }

  tags = merge(var.tags, { Name = local.hours_of_operation_name })
}
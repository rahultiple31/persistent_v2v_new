output "view_id" {
  value = awscc_connect_view.customer_details.view_id
}

output "view_arn" {
  value = awscc_connect_view.customer_details.view_arn
}

output "view_latest_arn" {
  value = "${awscc_connect_view.customer_details.view_arn}:$LATEST"
}

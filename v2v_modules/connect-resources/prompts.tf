# Default prompts created by Connect with every instance.
data "aws_connect_prompt" "default" {
  for_each = toset(var.default_prompt_names)

  instance_id = local.instance_id
  name        = each.value
}

# Custom prompt migrated from the source instance. hashicorp/aws has no prompt
# resource, so awscc is used. Created once moh_30sec_prompt_s3_uri is supplied.
resource "awscc_connect_prompt" "moh_30sec" {
  count = var.moh_30sec_prompt_s3_uri != null ? 1 : 0

  instance_arn = local.instance_arn
  name         = "MOH_30SEC"
  description  = "30 second music on hold."
  s3_uri       = var.moh_30sec_prompt_s3_uri
  tags         = local.awscc_tags
}

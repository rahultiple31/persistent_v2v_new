data "aws_connect_instance" "selected" {
  instance_alias = var.connect_instance_alias
}

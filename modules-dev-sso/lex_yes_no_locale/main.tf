resource "terraform_data" "locale" {
  triggers_replace = {
    configuration = jsonencode(var.configuration)
    script_hash   = filesha256("${path.module}/configure_locale.py")
  }

  provisioner "local-exec" {
    interpreter = ["python"]
    command     = abspath("${path.module}/configure_locale.py")

    environment = {
      LEX_CONFIGURATION = self.triggers_replace.configuration
    }
  }
}

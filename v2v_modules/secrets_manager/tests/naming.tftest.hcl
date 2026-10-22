mock_provider "aws" {}

variables {
  secrets = {
    "btsgsd-dev-sample"                = { value = "test-only" }
    "btsgsd-existing"                  = { value = "test-only" }
    "BTSGSD-SSO-US-survey"             = { value = "test-only" }
    "btsgsd-dev-us-east-1-reporting"   = { value = "test-only" }
    "servicenow/example"               = { value = "test-only" }
    "BTSGSD-V2V-US-already-prefixed"   = { value = "test-only" }
    "servicenow/stage-dev"             = { value = "test-only" }
    "Nextthink/Clientid/Secretkey-dev" = { value = "test-only" }
    "BTSGSD-V2V-US-SNOW_btsgsd-dev"    = { value = "test-only" }
    "btsgsd-dev-survey-dev"            = { value = "test-only" }
  }
}

run "prefix_new_names_without_changing_secret_keys" {
  command = plan

  assert {
    condition = (
      aws_secretsmanager_secret.this["btsgsd-dev-sample"].name == "BTSGSD-V2V-US-sample" &&
      aws_secretsmanager_secret.this["btsgsd-existing"].name == "BTSGSD-V2V-US-existing" &&
      aws_secretsmanager_secret.this["BTSGSD-SSO-US-survey"].name == "BTSGSD-V2V-US-survey" &&
      aws_secretsmanager_secret.this["btsgsd-dev-us-east-1-reporting"].name == "BTSGSD-V2V-US-reporting" &&
      aws_secretsmanager_secret.this["servicenow/example"].name == "BTSGSD-V2V-US-servicenow/example" &&
      aws_secretsmanager_secret.this["BTSGSD-V2V-US-already-prefixed"].name == "BTSGSD-V2V-US-already-prefixed" &&
      aws_secretsmanager_secret.this["servicenow/stage-dev"].name == "BTSGSD-V2V-US-servicenow/stage" &&
      aws_secretsmanager_secret.this["Nextthink/Clientid/Secretkey-dev"].name == "BTSGSD-V2V-US-Nextthink/Clientid/Secretkey" &&
      aws_secretsmanager_secret.this["BTSGSD-V2V-US-SNOW_btsgsd-dev"].name == "BTSGSD-V2V-US-SNOW" &&
      aws_secretsmanager_secret.this["btsgsd-dev-survey-dev"].name == "BTSGSD-V2V-US-survey"
    )
    error_message = "Normalize prefixes and trailing Dev suffixes without changing secret map keys or duplicating the V2V prefix."
  }
}

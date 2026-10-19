mock_provider "aws" {
  mock_resource "aws_connect_instance" {
    defaults = {
      id  = "c227a737-3e4f-4c64-8397-2d37e318801d"
      arn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d"
    }
  }

  mock_data "aws_connect_queue" {
    defaults = {
      arn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/queue/33333333-3333-3333-3333-333333333333"
    }
  }

  mock_data "aws_connect_contact_flow" {
    defaults = {
      arn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/contact-flow/44444444-4444-4444-4444-444444444444"
    }
  }
}

mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = {
        content = "{\"Version\":\"2019-10-30\",\"StartAction\":\"done\",\"Actions\":[{\"Identifier\":\"done\",\"Type\":\"EndFlowExecution\",\"Parameters\":{},\"Transitions\":{}}]}"
      }
    }
  }
}

variables {
  project_name         = "btsgsd"
  environment          = "dev"
  aws_region           = "us-east-1"
  region_code          = "us-east-1"
  common_tags          = {}
  contact_center_alias = "btsgsd"

  customer_number_data_table_id = "22222222-2222-2222-2222-222222222222"
  agent_ui_flow_arn             = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/contact-flow/55555555-5555-5555-5555-555555555555"

  imported_contact_flows = {
    main_inbound = {
      name    = "btsgsd-Main-IB-Flow"
      type    = "CONTACT_FLOW"
      content = file("../../environments/dev/metadata/contact-flows/BTSGSD-Main-IB-Flow.json")
    }
    customer_queue = {
      name    = "btsgsd_Abbvie_CustomerQueueFlow"
      type    = "CUSTOMER_QUEUE"
      content = file("../../environments/dev/metadata/contact-flows/BTSGSD_Abbvie_CustomerQueueFlow.json")
    }
  }
}

run "lang_config_uses_created_table_id" {
  command = apply

  assert {
    condition = (
      [for action in jsondecode(aws_connect_contact_flow.imported_main_inbound["main_inbound"].content).Actions : action.Parameters.QueueId if action.Identifier == "Escalate"] == ["arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/queue/33333333-3333-3333-3333-333333333333"] &&
      [for action in jsondecode(aws_connect_contact_flow.imported_main_inbound["main_inbound"].content).Actions : action.Parameters.ContactFlowId if action.Identifier == "Survey FLow"] == ["arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/contact-flow/44444444-4444-4444-4444-444444444444"] &&
      [for action in jsondecode(aws_connect_contact_flow.imported_main_inbound["main_inbound"].content).Actions : action.Parameters.EventHooks.DefaultAgentUI if action.Identifier == "094ab93e-10a1-410f-a7b5-4b7eca2aafe4"] == [var.agent_ui_flow_arn] &&
      !strcontains(aws_connect_contact_flow.imported_main_inbound["main_inbound"].content, "instance/0cc3e955-8cdd-4a82-b6fe-7593e1674ffa/")
    )
    error_message = "Inbound routing and survey references must use resources from the target instance, including metadata."
  }

  assert {
    condition = (
      [for action in jsondecode(aws_connect_contact_flow.imported_main_inbound["main_inbound"].content).Actions : action.Parameters.DataTableId if action.Identifier == "Load lang config"] == ["22222222-2222-2222-2222-222222222222"] &&
      !strcontains(aws_connect_contact_flow.imported_main_inbound["main_inbound"].content, "__CUSTOMER_NUMBER_DATA_TABLE_ID__")
    )
    error_message = "LangConfig must receive the created table ID with no unresolved token."
  }

  assert {
    condition = (
      [for action in jsondecode(aws_connect_contact_flow.imported_main_inbound["main_inbound"].content).Actions : action.Parameters.Queries[0].PrimaryValues[0].Value if action.Identifier == "Load lang config"] == ["$.SystemEndpoint.Address"] &&
      [for action in jsondecode(aws_connect_contact_flow.imported_main_inbound["main_inbound"].content).Actions : action.Parameters.DataTableId if action.Identifier == "TopLevelBlocker_Message"] == ["e0917ae9-956c-4e02-b73f-43150201aa7f"]
    )
    error_message = "Preserve the dialed-number lookup and unrelated data-table references."
  }
}

run "target_dependency_name_overrides" {
  command = plan

  variables {
    customer_queue_dependency_names = {
      "BTSGSD-US-MAIN-QUEUE"      = "Dev Main Queue"
      "BTSGSD-AIAgent-SurveyFlow" = "Dev Survey Flow"
    }
  }

  assert {
    condition = (
      data.aws_connect_queue.main_inbound[0].name == "Dev Main Queue" &&
      data.aws_connect_contact_flow.main_inbound_survey[0].name == "Dev Survey Flow" &&
      data.aws_connect_queue.main_inbound[0].instance_id == aws_connect_instance.this.id &&
      data.aws_connect_contact_flow.main_inbound_survey[0].instance_id == aws_connect_instance.this.id
    )
    error_message = "Dependency overrides must look up the configured names in the managed Connect instance."
  }
}

run "no_inbound_skips_dependency_lookups" {
  command = plan

  variables {
    imported_contact_flows = {}
  }

  assert {
    condition = (
      length(data.aws_connect_queue.main_inbound) == 0 &&
      length(data.aws_connect_contact_flow.main_inbound_survey) == 0
    )
    error_message = "Deployments without the main inbound flow must not require the queue or survey."
  }
}

run "reject_agent_ui_from_source_instance" {
  command = plan

  variables {
    agent_ui_flow_arn = "arn:aws:connect:us-east-1:518902362956:instance/0cc3e955-8cdd-4a82-b6fe-7593e1674ffa/contact-flow/7f068b9c-c1bc-4a43-a26d-a317570a8cd4"
  }

  expect_failures = [aws_connect_contact_flow.imported_main_inbound["main_inbound"]]
}

run "managed_survey_skips_lookup_and_updates_inbound" {
  command = apply

  variables {
    lookup_main_inbound_survey   = false
    main_inbound_survey_flow_arn = "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/contact-flow/66666666-6666-6666-6666-666666666666"
  }

  assert {
    condition = (
      length(data.aws_connect_contact_flow.main_inbound_survey) == 0 &&
      [for action in jsondecode(aws_connect_contact_flow.imported_main_inbound["main_inbound"].content).Actions : action.Parameters.ContactFlowId if action.Identifier == "Survey FLow"] == [var.main_inbound_survey_flow_arn]
    )
    error_message = "The inbound flow must use the newly managed survey ARN without looking up a flow that does not exist yet."
  }
}

run "managed_survey_requires_target_instance_arn" {
  command = plan

  variables {
    lookup_main_inbound_survey   = false
    main_inbound_survey_flow_arn = "arn:aws:connect:us-east-1:518902362956:instance/0cc3e955-8cdd-4a82-b6fe-7593e1674ffa/contact-flow/3ac7b9d3-411e-4762-9d86-d74c70b54a94"
  }

  expect_failures = [aws_connect_contact_flow.imported_main_inbound["main_inbound"]]
}

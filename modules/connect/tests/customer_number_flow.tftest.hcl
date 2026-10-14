mock_provider "aws" {}

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

  imported_contact_flows = {
    main_inbound = {
      name    = "btsgsd-Main-IB-Flow.json"
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

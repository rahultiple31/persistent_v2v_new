# Amazon Connect generates the input schema from this layout.
# The supplied JSON Schema cannot be passed directly as the view template.
resource "awscc_connect_view" "customer_information" {
  count    = local.deploy_connect ? 1 : 0
  provider = awscc.us_east_1

  name         = "BTSGSD-V2V-US-Customer Information"
  instance_arn = module.connect_us_east_1[0].instance_arn
  description  = "Customer Information View"
  actions      = ["Close"]

  template = jsonencode({
    Head = {
      Title = "Customer Information"
      Configuration = {
        Layout = {
          Columns = [12]
        }
      }
    }

    Body = [
      {
        _id = "CustomerInformationHeader"
        Type = "Header"
        Props = {
          variant = "h2"
        }
        Content = ["Customer Information"]
      },
      {
        _id = "CustomerInformationAttributes"
        Type = "AttributeSection"
        Props = {
          Heading = "Caller information"
          Columns = 2
          Items = [
            { Label = "Caller name", Value = "$.CallerName" },
            { Label = "User status", Value = "$.UserStatus" },
            { Label = "User ID", Value = "$.UserId" },
            { Label = "Email", Value = "$.Email" },
            { Label = "UPI", Value = "$.UPI" },
            { Label = "Dialed number", Value = "$.DialedNumber" },
            { Label = "Verification status", Value = "$.VerificationStatus" },
            { Label = "Verified via", Value = "$.VerifiedVia" },
            { Label = "Intent", Value = "$.Intent" },
            {
              Label = "Preferred language"
              Value = "$.Customer_Prefferred_Language"
            }
          ]
        }
        Content = []
      },
      {
        _id = "CustomerInformationSummaryHeader"
        Type = "Header"
        Props = {
          variant = "h3"
        }
        Content = ["Call summary"]
      },
      {
        _id = "CustomerInformationSummaryText"
        Type = "TextBox"
        Props = {
          Variant = "p"
        }
        Content = ["$.CallSummary"]
      },
      {
        _id = "CloseCustomerInformation"
        Type = "Button"
        Props = {
          Variant = "primary"
          Action  = "Close"
        }
        Content = ["Close"]
      }
    ]
  })

  tags = [
    for key, value in local.common_tags : {
      key   = key
      value = value
    }
  ]
}

output "customer_information_view" {
  description = "Customer Information view identifiers."

  value = local.deploy_connect ? {
    view_id         = awscc_connect_view.customer_information[0].view_id
    view_arn        = awscc_connect_view.customer_information[0].view_arn
    view_latest_arn = "${awscc_connect_view.customer_information[0].view_arn}:$LATEST"
  } : null
}

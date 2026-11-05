# btsgsd-Main-IB-Flow (3).json

{
  "Version": "2019-10-30",
  "StartAction": "Set logging",
  "Metadata": {
    "entryPointPosition": {
      "x": 2460,
      "y": 2060
    },
    "ActionMetadata": {
      "Set voice_fallback": {
        "position": {
          "x": 3920,
          "y": 2340
        },
        "isFriendlyName": true,
        "children": [
          "Set voice_fallback-MLbw1V9oDW"
        ],
        "parameters": {
          "TextToSpeechVoice": {
            "languageCode": "en-US"
          },
          "TextToSpeechEngine": {
            "voiceProvider": "connect:agentic"
          }
        },
        "overrideConsoleVoice": true,
        "fragments": {
          "SetContactData": "Set voice_fallback-MLbw1V9oDW"
        },
        "overrideLanguageAttribute": true
      },
      "Set voice_fallback-MLbw1V9oDW": {
        "position": {
          "x": 3920,
          "y": 2340
        },
        "isFriendlyName": true,
        "dynamicParams": []
      },
      "Set voice": {
        "position": {
          "x": 3640,
          "y": 2080
        },
        "isFriendlyName": true,
        "children": [
          "Set voice-qmFTc7Dv41"
        ],
        "parameters": {
          "TextToSpeechVoice": {
            "useDynamic": true,
            "languageCode": "$.Attributes.language_name"
          },
          "TextToSpeechEngine": {
            "voiceProvider": "connect:agentic"
          }
        },
        "overrideConsoleVoice": true,
        "fragments": {
          "SetContactData": "Set voice-qmFTc7Dv41"
        },
        "overrideLanguageAttribute": true
      },
      "Set voice-qmFTc7Dv41": {
        "position": {
          "x": 3640,
          "y": 2080
        },
        "isFriendlyName": true,
        "parameters": {
          "LanguageCode": {
            "useDynamic": true
          }
        },
        "dynamicParams": [
          "languageCode"
        ]
      },
      "Get customer input-L4Nj72lYly": {
        "position": {
          "x": 4760,
          "y": 2600
        },
        "isFriendlyName": true,
        "children": [
          "Get customer input-L4Nj72lYly-UOlKGhISji",
          "Get customer input-L4Nj72lYly-1wDKkEylWU"
        ],
        "parameters": {
          "WisdomAssistantArn": {
            "useAIAgentDropdown": true,
            "aiAgentName": "btsgsd-SupportAgent",
            "aiAgentVersionArn": "arn:aws:wisdom:us-east-1:518902362956:ai-agent/bc274e3f-380d-45e7-968f-2d19f92acd74/c1c0c6cf-2e49-4091-bb06-85f9e7095a96:42"
          }
        },
        "fragments": {
          "SetContactData": "Get customer input-L4Nj72lYly-UOlKGhISji"
        },
        "useAIAgentDropdown": true,
        "aiAgentName": "btsgsd-SupportAgent",
        "aiAgentVersionArn": "arn:aws:wisdom:us-east-1:518902362956:ai-agent/bc274e3f-380d-45e7-968f-2d19f92acd74/c1c0c6cf-2e49-4091-bb06-85f9e7095a96:42"
      },
      "Get customer input-L4Nj72lYly-UOlKGhISji": {
        "position": {
          "x": 4760,
          "y": 2600
        },
        "isFriendlyName": true,
        "dynamicParams": []
      },
      "Get customer input-L4Nj72lYly-1wDKkEylWU": {
        "position": {
          "x": 4760,
          "y": 2600
        },
        "isFriendlyName": true,
        "parameters": {
          "Text": {
            "useDynamic": true
          },
          "LexV2Bot": {
            "AliasArn": {
              "displayName": "btsgsd-alias-dev-sso",
              "useLexBotDropdown": true,
              "lexV2BotName": "btsgsd-IT-Support_Agent-dev"
            }
          },
          "LexSessionAttributes": {
            "x-amz-lex:audio:locale-override": {
              "useDynamic": true
            }
          }
        },
        "dynamicMetadata": {
          "x-amz-lex:audio:locale-override": true,
          "x-amz-lex:q-in-connect:session-arn": false,
          "x-amz-lex:allow-interrupt:*:*": false,
          "x-amz-lex:audio:start-timeout-ms:*:*": false,
          "x-amz-lex:audio:end-timeout-ms:*:*": false,
          "x-amz-lex:audio:max-length-ms:*:*": false,
          "x-amz-lex:q-in-connect:ai-agent-arn": false
        },
        "useLexBotDropdown": true,
        "lexV2BotName": "btsgsd-IT-Support_Agent-dev",
        "lexV2BotAliasName": "btsgsd-alias-dev-sso",
        "useDynamic": true,
        "conditionMetadata": []
      },
      "Connect assistant": {
        "position": {
          "x": 3920,
          "y": 2080
        },
        "isFriendlyName": true,
        "children": [
          "Connect assistant-fPhgAg1ZLP"
        ],
        "parameters": {
          "OrchestrationAIAgentConfiguration": {
            "AgentAssistanceAgentVersionArn": {
              "useAIAgentDropdown": true,
              "aiAgentName": "btsgsd-SupportAgent"
            }
          }
        },
        "fragments": {
          "SetContactData": "Connect assistant-fPhgAg1ZLP"
        },
        "useAIAgentDropdown": true,
        "aiAgentName": "btsgsd-SupportAgent"
      },
      "Connect assistant-fPhgAg1ZLP": {
        "position": {
          "x": 3920,
          "y": 2080
        },
        "isFriendlyName": true,
        "dynamicParams": []
      },
      "Guard_Lambda_Escalate": {
        "position": {
          "x": 5320,
          "y": 1040
        },
        "isFriendlyName": true,
        "parameters": {
          "LambdaFunctionARN": {
            "displayName": "silence_guard-dev"
          }
        },
        "dynamicMetadata": {
          "ExpectedTool": false,
          "Tool": false,
          "Intent": false,
          "CallSummary": false,
          "VerificationStatus": false,
          "VerifiedVia": false,
          "RoutingIntent": false,
          "ContactId": false,
          "reason": false,
          "region": false
        }
      },
      "Set_Lookup_Matched": {
        "position": {
          "x": 4760,
          "y": 1040
        },
        "isFriendlyName": true,
        "parameters": {
          "Attributes": {
            "FirstName": {
              "useDynamic": true
            },
            "LastName": {
              "useDynamic": true
            },
            "UPI": {
              "useDynamic": true
            },
            "UserId": {
              "useDynamic": true
            },
            "Email": {
              "useDynamic": true
            },
            "FieldForce": {
              "useDynamic": true
            },
            "Active": {
              "useDynamic": true
            },
            "UserStatus": {
              "useDynamic": true
            }
          }
        },
        "dynamicParams": [
          "FirstName",
          "LastName",
          "UPI",
          "UserId",
          "Email",
          "FieldForce",
          "Active",
          "UserStatus"
        ]
      },
      "Guard_Decision_Complete": {
        "position": {
          "x": 5600,
          "y": 1300
        },
        "isFriendlyName": true,
        "conditions": [],
        "conditionMetadata": [
          {
            "id": "3cf9917a-7830-4763-843b-9ff12dfddec1",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "true"
          },
          {
            "id": "ab3957a4-8966-4608-928b-d39aa1475d3f",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "false"
          }
        ]
      },
      "Guard_Recovery_Message": {
        "position": {
          "x": 5880,
          "y": 1040
        },
        "isFriendlyName": true
      },
      "Guard_Recovery_Disconnect": {
        "position": {
          "x": 6160,
          "y": 1300
        },
        "isFriendlyName": true
      },
      "Survey FLow": {
        "position": {
          "x": 6720,
          "y": 1300
        },
        "isFriendlyName": true,
        "parameters": {
          "ContactFlowId": {
            "displayName": "BTSGSD-AIAgent-SurveyFlow"
          }
        },
        "ContactFlow": {
          "text": "BTSGSD-AIAgent-SurveyFlow"
        }
      },
      "be655205-0b97-41e2-8da1-43c3b0d4c9b0": {
        "position": {
          "x": 6440,
          "y": 1300
        },
        "dynamicParams": []
      },
      "TechSpot-HandOff": {
        "position": {
          "x": 5880,
          "y": 1300
        },
        "isFriendlyName": true,
        "conditions": [],
        "conditionMetadata": [
          {
            "id": "307553ab-5aae-4e22-9b32-0dadce384f1a",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "Techspot - Teams Handoff"
          },
          {
            "id": "39ab2c85-979f-4a07-9d02-bbd26eb9d303",
            "operator": {
              "name": "Contains",
              "value": "Contains",
              "shortDisplay": "contains"
            },
            "value": "Out of Scope"
          },
          {
            "id": "37bdb47d-4623-49c2-a150-8b5d839f1dee",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "Patient/Customer - Misroute"
          },
          {
            "id": "d92d54ce-3d49-4a52-ad14-7ffebacd892a",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "Techspot - Other IT"
          },
          {
            "id": "a6934cf1-571e-4c78-87e3-e992c711d616",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "Unverified - Verification Failed"
          }
        ]
      },
      "TechSpot_Handoff": {
        "position": {
          "x": 6160,
          "y": 1560
        },
        "isFriendlyName": true,
        "parameters": {
          "SSML": {
            "useDynamic": true
          }
        },
        "useDynamic": true
      },
      "Phone_Lookup": {
        "position": {
          "x": 4200,
          "y": 1040
        },
        "isFriendlyName": true,
        "parameters": {
          "LambdaFunctionARN": {
            "displayName": "SNOW_btsgsd-dev"
          }
        },
        "dynamicMetadata": {
          "caller_ani": false
        }
      },
      "Check_PhoneLookupStatus": {
        "position": {
          "x": 4480,
          "y": 1040
        },
        "isFriendlyName": true,
        "conditions": [],
        "conditionMetadata": [
          {
            "id": "e22231cb-1511-4522-bdd7-dab556a4e59b",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "Matched"
          },
          {
            "id": "66a7942c-0ef6-4d94-a2cc-2df314d0c689",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "NotMatched"
          }
        ]
      },
      "Verify_Intro_Message": {
        "position": {
          "x": 3920,
          "y": 1040
        },
        "isFriendlyName": true
      },
      "Set_Lookup_NotMatched": {
        "position": {
          "x": 5040,
          "y": 1040
        },
        "isFriendlyName": true,
        "dynamicParams": []
      },
      "Set_Lookup": {
        "position": {
          "x": 4760,
          "y": 1300
        },
        "isFriendlyName": true,
        "dynamicParams": []
      },
      "Set_Lookup_Error": {
        "position": {
          "x": 4480,
          "y": 1560
        },
        "isFriendlyName": true,
        "dynamicParams": []
      },
      "Tech_Failure_Message": {
        "position": {
          "x": 5880,
          "y": 2080
        },
        "isFriendlyName": true,
        "parameters": {
          "SSML": {
            "useDynamic": false
          }
        }
      },
      "region_check": {
        "position": {
          "x": 5600,
          "y": 1560
        },
        "isFriendlyName": true,
        "conditions": [],
        "conditionMetadata": [
          {
            "id": "35e7e251-e379-4cfa-9b0f-fc51247704c7",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "LATAM"
          }
        ]
      },
      "627c5ca8-9b09-4092-8b60-47aee2cb9ed6": {
        "position": {
          "x": 7560,
          "y": 1820
        }
      },
      "Queue_Unavailable_Message": {
        "position": {
          "x": 7840,
          "y": 1820
        },
        "isFriendlyName": true
      },
      "041ad0bc-26e4-414f-b8e2-efdc80f0f5e8": {
        "position": {
          "x": 7560,
          "y": 2080
        }
      },
      "Guard_Lambda_Complete": {
        "position": {
          "x": 5320,
          "y": 1300
        },
        "isFriendlyName": true,
        "parameters": {
          "LambdaFunctionARN": {
            "displayName": "silence_guard-dev"
          }
        },
        "dynamicMetadata": {
          "ExpectedTool": false,
          "Tool": false,
          "Intent": false,
          "CallSummary": false,
          "VerificationStatus": false,
          "VerifiedVia": false,
          "RoutingIntent": false,
          "ContactId": false,
          "reason": false,
          "region": false
        }
      },
      "Tech_Failure_Check": {
        "position": {
          "x": 5600,
          "y": 2080
        },
        "isFriendlyName": true,
        "conditions": [],
        "conditionMetadata": [
          {
            "id": "330a7c52-5194-4998-b2f5-16e8f40e64af",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "Unverified - Lookup Error"
          }
        ]
      },
      "19197f54-b210-41e2-8f4c-8f86a2c11dad": {
        "position": {
          "x": 3360,
          "y": 2080
        },
        "parameters": {
          "VoiceBehavior": {
            "VoiceAnalyticsBehavior": {
              "AnalyticsLanguage": {
                "useDynamic": true
              }
            }
          }
        }
      },
      "3f3dbe3b-6046-4b02-b0b1-7b8502436f52": {
        "position": {
          "x": 4200,
          "y": 2340
        },
        "dynamicParams": []
      },
      "f998f5e7-eb1b-4011-95f1-af7f8b72997a": {
        "position": {
          "x": 6720,
          "y": 1560
        },
        "parameters": {
          "QueueId": {
            "useDynamic": true
          }
        },
        "useDynamic": true
      },
      "LATAM_Queue": {
        "position": {
          "x": 5600,
          "y": 1820
        },
        "isFriendlyName": true,
        "parameters": {
          "QueueId": {
            "displayName": "BTSGSD-DEV-SSO-LATAM-MAIN-QUEUE"
          }
        },
        "queue": {
          "text": "BTSGSD-DEV-SSO-LATAM-MAIN-QUEUE"
        }
      },
      "b69a2aad-6fef-4349-a839-e1fbf206f2d3": {
        "position": {
          "x": 6440,
          "y": 1820
        },
        "parameters": {
          "EventHooks": {
            "CustomerQueue": {
              "displayName": "BTSGSD_Abbvie_CustomerQueueFlow"
            }
          }
        },
        "contactFlow": {
          "text": "BTSGSD_Abbvie_CustomerQueueFlow",
          "id": "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/contact-flow/cb5f9c2f-a0a3-4f42-a865-fc22d872938c"
        },
        "customerOrAgent": true
      },
      "0323e84a-b89e-466c-bd65-aa96cf580f9d": {
        "position": {
          "x": 6160,
          "y": 1820
        },
        "parameters": {
          "LambdaFunctionARN": {
            "displayName": "conversionOfQueueMetrics-dev"
          }
        },
        "dynamicMetadata": {
          "invocationType": false
        }
      },
      "1e776648-1130-4181-91e3-f5b531154afe": {
        "position": {
          "x": 5880,
          "y": 1820
        },
        "parameters": {
          "Attributes": {
            "Customer_Prefferred_Language": {
              "useDynamic": true
            },
            "V2V_agentLanguage": {
              "useDynamic": true
            },
            "V2V_customerVoiceId": {
              "useDynamic": true
            }
          }
        },
        "dynamicParams": [
          "Customer_Prefferred_Language",
          "V2V_agentLanguage",
          "V2V_customerVoiceId"
        ]
      },
      "Escalate": {
        "position": {
          "x": 5880,
          "y": 2340
        },
        "isFriendlyName": true,
        "parameters": {
          "QueueId": {
            "displayName": "BTSGSD-DEV SSO-US-MAIN-QUEUE"
          }
        },
        "queue": {
          "text": "BTSGSD-DEV SSO-US-MAIN-QUEUE"
        }
      },
      "error_message_2": {
        "position": {
          "x": 6440,
          "y": 2340
        },
        "isFriendlyName": true
      },
      "f727499b-f040-4392-b1bd-a46af3bc15ce": {
        "position": {
          "x": 6720,
          "y": 2340
        }
      },
      "LATAM_Silent_Check": {
        "position": {
          "x": 5320,
          "y": 780
        },
        "isFriendlyName": true,
        "conditions": [],
        "conditionMetadata": [
          {
            "id": "3ebfc793-8b89-4379-9f83-2aedc658bca6",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "LATAM"
          }
        ]
      },
      "Guard_Decision_Escalate": {
        "position": {
          "x": 5600,
          "y": 1040
        },
        "isFriendlyName": true,
        "conditions": [],
        "conditionMetadata": [
          {
            "id": "cdca10e2-717e-484d-82ec-acf31291180b",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "true"
          },
          {
            "id": "d1523e90-7651-4a3c-a8a3-7de19893d1e2",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "false"
          }
        ]
      },
      "Silent_Route_Check": {
        "position": {
          "x": 5040,
          "y": 780
        },
        "isFriendlyName": true,
        "conditions": [],
        "conditionMetadata": [
          {
            "id": "c292f56e-6b70-4cd5-b7a5-2ade80b540c6",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "FieldForce"
          },
          {
            "id": "9b968542-be70-4f43-b445-99dd5553f99f",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "Veeva"
          },
          {
            "id": "2ed91709-abc8-49c8-83bd-11edfd2f03f0",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "Medcom"
          }
        ]
      },
      "HR_Helpdesk": {
        "position": {
          "x": 5880,
          "y": 2600
        },
        "isFriendlyName": true,
        "parameters": {
          "ThirdPartyPhoneNumber": {
            "countryCode": "",
            "useDynamic": true
          }
        }
      },
      "hr_Transfer": {
        "position": {
          "x": 5880,
          "y": 2860
        },
        "isFriendlyName": true,
        "parameters": {
          "SSML": {
            "useDynamic": true
          }
        },
        "useDynamic": true
      },
      "MedCom_Helpdesk": {
        "position": {
          "x": 6440,
          "y": 2600
        },
        "isFriendlyName": true,
        "parameters": {
          "ThirdPartyPhoneNumber": {
            "countryCode": "",
            "useDynamic": true
          }
        }
      },
      "Medcom_Transfer": {
        "position": {
          "x": 6160,
          "y": 2860
        },
        "isFriendlyName": true
      },
      "playprompt_1": {
        "position": {
          "x": 6160,
          "y": 2340
        },
        "isFriendlyName": true
      },
      "Veeva_Helpdesk": {
        "position": {
          "x": 6440,
          "y": 2860
        },
        "isFriendlyName": true,
        "parameters": {
          "ThirdPartyPhoneNumber": {
            "countryCode": "",
            "useDynamic": true
          }
        }
      },
      "Veeva_transfer": {
        "position": {
          "x": 6160,
          "y": 3380
        },
        "isFriendlyName": true
      },
      "Welcome_Greeting": {
        "position": {
          "x": 4200,
          "y": 1820
        },
        "isFriendlyName": true,
        "parameters": {
          "SSML": {
            "useDynamic": false
          }
        }
      },
      "Routing_check": {
        "position": {
          "x": 5600,
          "y": 2860
        },
        "isFriendlyName": true,
        "conditions": [],
        "conditionMetadata": [
          {
            "id": "bcf5adfa-5da2-48b2-8cf4-3286869e9450",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "HR"
          },
          {
            "id": "5663d18b-37b1-4831-aca4-a41d7a32e190",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "FieldForce"
          },
          {
            "id": "627a37e1-7cff-4429-b976-983d317f01ce",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "Veeva"
          },
          {
            "id": "9b5d4867-0879-481b-a654-545ccaa48ff6",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "Medcom"
          }
        ]
      },
      "FieldForce_Helpdesk": {
        "position": {
          "x": 6160,
          "y": 2600
        },
        "isFriendlyName": true,
        "parameters": {
          "ThirdPartyPhoneNumber": {
            "countryCode": "US"
          }
        },
        "CountryCode": "us"
      },
      "FieldForce_Transfer": {
        "position": {
          "x": 5880,
          "y": 3120
        },
        "isFriendlyName": true
      },
      "f386788a-82c6-4075-86bb-20da1068f52b": {
        "position": {
          "x": 3920,
          "y": 1820
        }
      },
      "430a3acf-25ed-45c4-bcd5-4741bb2c619c": {
        "position": {
          "x": 3640,
          "y": 1820
        },
        "parameters": {
          "DataTableId": {
            "displayName": "BTSGSD-Survey-DataTable"
          }
        }
      },
      "FF_Verified_Check": {
        "position": {
          "x": 5600,
          "y": 3380
        },
        "isFriendlyName": true,
        "conditions": [],
        "conditionMetadata": [
          {
            "id": "992941c4-86f9-40bc-b9d8-2491368aa193",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "Authenticated"
          }
        ]
      },
      "198a2484-f8fe-4d09-b80b-2b7336893aa1": {
        "position": {
          "x": 7000,
          "y": 1300
        }
      },
      "ff_unverified_message": {
        "position": {
          "x": 6159.2,
          "y": 3118.4
        },
        "isFriendlyName": true,
        "parameters": {
          "SSML": {
            "useDynamic": false
          }
        }
      },
      "FF_Unverified_Fallback": {
        "position": {
          "x": 6160,
          "y": 3900
        },
        "isFriendlyName": true
      },
      "LiveAgent_Line_Check": {
        "position": {
          "x": 5600,
          "y": 3640
        },
        "isFriendlyName": true,
        "conditions": [],
        "conditionMetadata": [
          {
            "id": "0aa8964d-fff5-4545-8f84-80e0ba14967d",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "Veeva - Live Agent"
          },
          {
            "id": "d02d8bb4-6167-41d7-9471-9a0bbc7f987b",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "Medcom - Live Agent"
          }
        ]
      },
      "liveAgent_transfer_message": {
        "position": {
          "x": 6160,
          "y": 3639.2
        },
        "isFriendlyName": true,
        "parameters": {
          "SSML": {
            "useDynamic": false
          }
        }
      },
      "LiveAgent_Transfer_Fallback": {
        "position": {
          "x": 6159.2,
          "y": 4159.2
        },
        "isFriendlyName": true
      },
      "TopLevelBlocker_Message": {
        "position": {
          "x": 3080,
          "y": 1820
        },
        "isFriendlyName": true,
        "parameters": {
          "DataTableId": {
            "displayName": "TopLevelBlockerMessage"
          }
        }
      },
      "b328f7b4-744f-4984-beb0-d270528bc8f6": {
        "position": {
          "x": 3360,
          "y": 1820
        },
        "parameters": {
          "Text": {
            "useDynamic": true
          }
        },
        "useDynamic": true
      },
      "Bot_Retry_Set": {
        "position": {
          "x": 4480,
          "y": 2860
        },
        "isFriendlyName": true,
        "parameters": {
          "Attributes": {
            "bot_retry": {
              "useDynamic": false
            },
            "OpeningPrompt": {
              "useDynamic": false
            }
          }
        },
        "dynamicParams": []
      },
      "Update session data": {
        "position": {
          "x": 4480,
          "y": 2080
        },
        "isFriendlyName": true,
        "parameters": {
          "LambdaFunctionARN": {
            "displayName": "UpdateSessionAttributes-dev"
          },
          "LambdaInvocationAttributes": {
            "language_name": {
              "useDynamic": true
            },
            "CallerAni": {
              "useDynamic": true
            },
            "ContactId": {
              "useDynamic": true
            },
            "PhoneLookupStatus": {
              "useDynamic": true
            },
            "FirstName": {
              "useDynamic": true
            },
            "LastName": {
              "useDynamic": true
            },
            "UPI": {
              "useDynamic": true
            },
            "UserId": {
              "useDynamic": true
            },
            "Email": {
              "useDynamic": true
            },
            "FieldForce": {
              "useDynamic": true
            },
            "Active": {
              "useDynamic": true
            },
            "UserStatus": {
              "useDynamic": true
            },
            "Region": {
              "useDynamic": true
            }
          }
        },
        "dynamicMetadata": {
          "language_name": true,
          "CallerAni": true,
          "ContactId": true,
          "PhoneLookupStatus": true,
          "FirstName": true,
          "LastName": true,
          "UPI": true,
          "UserId": true,
          "Email": true,
          "FieldForce": true,
          "Active": true,
          "UserStatus": true,
          "Region": true
        }
      },
      "Session_Update_Status_Check": {
        "position": {
          "x": 4760,
          "y": 2340
        },
        "isFriendlyName": true,
        "conditions": [],
        "conditionMetadata": [
          {
            "id": "62a7e7a5-74ce-41ee-8cea-bfb212bb85f3",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "success"
          }
        ]
      },
      "Bot_Retry_Check": {
        "position": {
          "x": 4760,
          "y": 2860
        },
        "isFriendlyName": true,
        "conditions": [],
        "conditionMetadata": [
          {
            "id": "27f1bec1-4820-45ec-8372-b2309b1b1ba2",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "1"
          }
        ]
      },
      "a6683a59-32ab-4db9-bad1-65a1f93f0b5e": {
        "position": {
          "x": 4760,
          "y": 2080
        },
        "parameters": {
          "Attributes": {
            "Tool": {
              "useDynamic": true
            },
            "Customer_Prefferred_Language": {
              "useDynamic": true
            },
            "RoutingIntent": {
              "useDynamic": true
            },
            "CallSummary": {
              "useDynamic": true
            },
            "ScreenPopURL": {
              "useDynamic": true
            },
            "Intent": {
              "useDynamic": true
            },
            "VerificationStatus": {
              "useDynamic": true
            },
            "VerifiedVia": {
              "useDynamic": true
            },
            "CallerName": {
              "useDynamic": true
            },
            "UPI": {
              "useDynamic": true
            },
            "UserId": {
              "useDynamic": true
            },
            "UserStatus": {
              "useDynamic": true
            },
            "Email": {
              "useDynamic": true
            },
            "Dialed_Number": {
              "useDynamic": true
            }
          }
        },
        "dynamicParams": [
          "Tool",
          "Customer_Prefferred_Language",
          "RoutingIntent",
          "CallSummary",
          "ScreenPopURL",
          "Intent",
          "VerificationStatus",
          "VerifiedVia",
          "CallerName",
          "UPI",
          "UserId",
          "UserStatus",
          "Email",
          "Dialed_Number"
        ]
      },
      "3b2f7d60-f6c2-48fd-885c-27bf7377c204": {
        "position": {
          "x": 5320,
          "y": 2080
        },
        "parameters": {
          "Attributes": {
            "IVR_Prefferred_Language": {
              "useDynamic": true
            }
          }
        },
        "dynamicParams": [
          "IVR_Prefferred_Language"
        ]
      },
      "Check contact attributes": {
        "position": {
          "x": 5600,
          "y": 2340
        },
        "isFriendlyName": true,
        "conditions": [],
        "conditionMetadata": [
          {
            "id": "c69d6957-8931-4d8d-a938-0bdd39706ef2",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "Escalate"
          },
          {
            "id": "d07bfe49-3ace-452e-a6b7-0f48b93cc4b7",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "Complete"
          }
        ]
      },
      "ca48f6f9-347e-4b45-a9cc-43c5c5a4d5fa": {
        "position": {
          "x": 5040,
          "y": 2080
        },
        "conditions": [],
        "conditionMetadata": [
          {
            "id": "e3f32121-3c97-4701-99ba-fda4bb809b85",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "en-US"
          },
          {
            "id": "bba1680e-f566-440b-8c5e-306b22eb073a",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "es-MX"
          },
          {
            "id": "27cbc978-3057-47b6-910f-919f7d563455",
            "operator": {
              "name": "Equals",
              "value": "Equals",
              "shortDisplay": "="
            },
            "value": "pt-BR"
          }
        ]
      },
      "16190622-3ff4-4f25-9840-c54b23d24eab": {
        "position": {
          "x": 5319.2,
          "y": 2340
        },
        "parameters": {
          "Attributes": {
            "IVR_Prefferred_Language": {
              "useDynamic": true
            }
          }
        },
        "dynamicParams": [
          "IVR_Prefferred_Language"
        ]
      },
      "ff4ce28b-f76a-430a-ba3f-b5bf60cdfb94": {
        "position": {
          "x": 5320,
          "y": 1560
        },
        "parameters": {
          "EventHooks": {
            "DefaultAgentUI": {
              "displayName": "AbbVie_Views",
              "useSetEventHook": true
            }
          }
        }
      },
      "Bot_Outage_Message": {
        "position": {
          "x": 5040,
          "y": 2599.2
        },
        "isFriendlyName": true,
        "parameters": {
          "SSML": {
            "useDynamic": false
          }
        }
      },
      "Set_Outage_Attributes": {
        "position": {
          "x": 5320,
          "y": 2860
        },
        "isFriendlyName": true,
        "parameters": {
          "Attributes": {
            "IVR_Prefferred_Language": {
              "useDynamic": true
            }
          }
        },
        "dynamicParams": [
          "IVR_Prefferred_Language"
        ]
      },
      "Survey Announcement": {
        "position": {
          "x": 7000,
          "y": 1560
        },
        "isFriendlyName": true,
        "parameters": {
          "SSML": {
            "useDynamic": true
          }
        },
        "useDynamic": true
      },
      "d9899688-e08c-4865-a827-2d22da50eb82": {
        "position": {
          "x": 7000,
          "y": 1820
        },
        "parameters": {
          "EventHooks": {
            "CustomerRemaining": {
              "displayName": "BTSGSD-AIAgent-SurveyFlow"
            }
          }
        },
        "contactFlow": {
          "text": "BTSGSD-AIAgent-SurveyFlow",
          "id": "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/contact-flow/e2bea420-1eb7-436e-a339-9add640158db"
        }
      },
      "d6d76975-d765-4cf9-a4af-136504b2ac12": {
        "position": {
          "x": 7000,
          "y": 2080
        },
        "dynamicParams": []
      },
      "dd7a2a0c-425f-49c5-a9e4-1251df5e2fe0": {
        "position": {
          "x": 2800,
          "y": 2340
        },
        "parameters": {
          "Attributes": {
            "country": {
              "useDynamic": true
            },
            "hr_contact": {
              "useDynamic": true
            },
            "language_name": {
              "useDynamic": true
            },
            "region": {
              "useDynamic": true
            },
            "veeva_contact": {
              "useDynamic": true
            },
            "medcom_contact": {
              "useDynamic": true
            },
            "amazon_voice": {
              "useDynamic": true
            },
            "language": {
              "useDynamic": true
            }
          }
        },
        "dynamicParams": [
          "country",
          "hr_contact",
          "language_name",
          "region",
          "veeva_contact",
          "medcom_contact",
          "amazon_voice",
          "language"
        ]
      },
      "a928eec3-603d-4c37-bfe4-823cd653c0f3": {
        "position": {
          "x": 3360,
          "y": 2340
        }
      },
      "Set logging": {
        "position": {
          "x": 2548.8,
          "y": 2068.8
        },
        "isFriendlyName": true
      },
      "Load lang config": {
        "position": {
          "x": 3080,
          "y": 2080
        },
        "isFriendlyName": true,
        "parameters": {
          "DataTableId": {
            "displayName": "BTS_GSD-CustomerNumber"
          }
        }
      },
      "d1656116-cba5-4a8d-9178-355a48bfdcf3": {
        "position": {
          "x": 2788,
          "y": 2052.8
        },
        "parameters": {
          "Attributes": {
            "OriginalContactId": {
              "useDynamic": true
            }
          }
        },
        "dynamicParams": [
          "OriginalContactId"
        ]
      }
    },
    "Annotations": [],
    "name": "btsgsd-Main-IB-Flow",
    "description": "Main inbound flow for btsgsd-dev-us-east-1.",
    "type": "contactFlow",
    "status": "PUBLISHED",
    "hash": {}
  },
  "Actions": [
    {
      "Parameters": {
        "TextToSpeechVoice": "KATIE",
        "TextToSpeechEngine": "connect:agentic"
      },
      "Identifier": "Set voice_fallback",
      "Type": "UpdateContactTextToSpeechVoice",
      "Transitions": {
        "NextAction": "Set voice_fallback-MLbw1V9oDW",
        "Errors": [
          {
            "NextAction": "3f3dbe3b-6046-4b02-b0b1-7b8502436f52",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "LanguageCode": "en-US"
      },
      "Identifier": "Set voice_fallback-MLbw1V9oDW",
      "Type": "UpdateContactData",
      "Transitions": {
        "NextAction": "3f3dbe3b-6046-4b02-b0b1-7b8502436f52",
        "Errors": [
          {
            "NextAction": "3f3dbe3b-6046-4b02-b0b1-7b8502436f52",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "TextToSpeechVoice": "$.Attributes.amazon_voice",
        "TextToSpeechEngine": "connect:agentic"
      },
      "Identifier": "Set voice",
      "Type": "UpdateContactTextToSpeechVoice",
      "Transitions": {
        "NextAction": "Set voice-qmFTc7Dv41",
        "Errors": [
          {
            "NextAction": "430a3acf-25ed-45c4-bcd5-4741bb2c619c",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "LanguageCode": "$.Attributes.language_name"
      },
      "Identifier": "Set voice-qmFTc7Dv41",
      "Type": "UpdateContactData",
      "Transitions": {
        "NextAction": "430a3acf-25ed-45c4-bcd5-4741bb2c619c",
        "Errors": [
          {
            "NextAction": "430a3acf-25ed-45c4-bcd5-4741bb2c619c",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "WisdomAssistantArn": "arn:aws:wisdom:us-east-1:518902362956:assistant/bc274e3f-380d-45e7-968f-2d19f92acd74"
      },
      "Identifier": "Get customer input-L4Nj72lYly",
      "Type": "CreateWisdomSession",
      "Transitions": {
        "NextAction": "Get customer input-L4Nj72lYly-UOlKGhISji",
        "Errors": [
          {
            "NextAction": "Bot_Retry_Check",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "WisdomSessionArn": "$.Wisdom.SessionArn"
      },
      "Identifier": "Get customer input-L4Nj72lYly-UOlKGhISji",
      "Type": "UpdateContactData",
      "Transitions": {
        "NextAction": "Get customer input-L4Nj72lYly-1wDKkEylWU",
        "Errors": [
          {
            "NextAction": "Bot_Retry_Check",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "Text": "$.Attributes.OpeningPrompt",
        "LexV2Bot": {
          "AliasArn": "arn:aws:lex:us-east-1:518902362956:bot-alias/RCKELE93XH/W64U0WXHCF"
        },
        "LexSessionAttributes": {
          "x-amz-lex:audio:locale-override": "$.Attributes.language_name",
          "x-amz-lex:q-in-connect:session-arn": "$.Wisdom.SessionArn",
          "x-amz-lex:allow-interrupt:*:*": "true",
          "x-amz-lex:audio:start-timeout-ms:*:*": "6500",
          "x-amz-lex:audio:end-timeout-ms:*:*": "1600",
          "x-amz-lex:audio:max-length-ms:*:*": "10000",
          "x-amz-lex:q-in-connect:ai-agent-arn": "arn:aws:wisdom:us-east-1:518902362956:ai-agent/bc274e3f-380d-45e7-968f-2d19f92acd74/c1c0c6cf-2e49-4091-bb06-85f9e7095a96:42"
        }
      },
      "Identifier": "Get customer input-L4Nj72lYly-1wDKkEylWU",
      "Type": "ConnectParticipantWithLexBot",
      "Transitions": {
        "NextAction": "Bot_Retry_Check",
        "Errors": [
          {
            "NextAction": "a6683a59-32ab-4db9-bad1-65a1f93f0b5e",
            "ErrorType": "NoMatchingCondition"
          },
          {
            "NextAction": "Bot_Retry_Check",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "WisdomAssistantArn": "arn:aws:wisdom:us-east-1:518902362956:assistant/bc274e3f-380d-45e7-968f-2d19f92acd74",
        "OrchestrationAIAgentConfiguration": {
          "AgentAssistanceAgentVersionArn": "arn:aws:wisdom:us-east-1:518902362956:ai-agent/bc274e3f-380d-45e7-968f-2d19f92acd74/c1c0c6cf-2e49-4091-bb06-85f9e7095a96:42"
        }
      },
      "Identifier": "Connect assistant",
      "Type": "CreateWisdomSession",
      "Transitions": {
        "NextAction": "Connect assistant-fPhgAg1ZLP",
        "Errors": [
          {
            "NextAction": "Bot_Outage_Message",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "WisdomSessionArn": "$.Wisdom.SessionArn"
      },
      "Identifier": "Connect assistant-fPhgAg1ZLP",
      "Type": "UpdateContactData",
      "Transitions": {
        "NextAction": "Update session data",
        "Errors": [
          {
            "NextAction": "Bot_Outage_Message",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "LambdaFunctionARN": "arn:aws:lambda:us-east-1:518902362956:function:silence_guard-dev",
        "InvocationTimeLimitSeconds": "8",
        "InvocationType": "SYNCHRONOUS",
        "LambdaInvocationAttributes": {
          "ExpectedTool": "Escalate",
          "Tool": "$.Attributes.Tool",
          "Intent": "$.Attributes.Intent",
          "CallSummary": "$.Attributes.CallSummary",
          "VerificationStatus": "$.Attributes.VerificationStatus",
          "VerifiedVia": "$.Attributes.VerifiedVia",
          "RoutingIntent": "$.Attributes.RoutingIntent",
          "ContactId": "$.ContactId",
          "reason": "$.Lex.SessionAttributes.reason",
          "region": "$.Attributes.region"
        },
        "ResponseValidation": {
          "ResponseType": "STRING_MAP"
        }
      },
      "Identifier": "Guard_Lambda_Escalate",
      "Type": "InvokeLambdaFunction",
      "Transitions": {
        "NextAction": "Guard_Decision_Escalate",
        "Errors": [
          {
            "NextAction": "Guard_Decision_Escalate",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "Attributes": {
          "PhoneLookupStatus": "Matched",
          "FirstName": "$.External.FirstName",
          "LastName": "$.External.LastName",
          "UPI": "$.External.UPI",
          "UserId": "$.External.UserId",
          "Email": "$.External.Email",
          "FieldForce": "$.External.FieldForce",
          "Active": "$.External.Active",
          "UserStatus": "$.External.UserStatus"
        },
        "TargetContact": "Current"
      },
      "Identifier": "Set_Lookup_Matched",
      "Type": "UpdateContactAttributes",
      "Transitions": {
        "NextAction": "Set_Lookup",
        "Errors": [
          {
            "NextAction": "Set_Lookup",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ComparisonValue": "$.External.GuardAllowed"
      },
      "Identifier": "Guard_Decision_Complete",
      "Type": "Compare",
      "Transitions": {
        "NextAction": "TechSpot-HandOff",
        "Conditions": [
          {
            "NextAction": "TechSpot-HandOff",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "true"
              ]
            }
          },
          {
            "NextAction": "Guard_Recovery_Message",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "false"
              ]
            }
          }
        ],
        "Errors": [
          {
            "NextAction": "TechSpot-HandOff",
            "ErrorType": "NoMatchingCondition"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "SSML": "<speak>$.DataTables.LanguageCheck.Guard_Recovery_Message</speak>"
      },
      "Identifier": "Guard_Recovery_Message",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "Guard_Recovery_Disconnect",
        "Errors": [
          {
            "NextAction": "Guard_Recovery_Disconnect",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {},
      "Identifier": "Guard_Recovery_Disconnect",
      "Type": "DisconnectParticipant",
      "Transitions": {}
    },
    {
      "Parameters": {
        "ContactFlowId": "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/contact-flow/e2bea420-1eb7-436e-a339-9add640158db"
      },
      "Identifier": "Survey FLow",
      "Type": "TransferToFlow",
      "Transitions": {
        "NextAction": "198a2484-f8fe-4d09-b80b-2b7336893aa1",
        "Errors": [
          {
            "NextAction": "198a2484-f8fe-4d09-b80b-2b7336893aa1",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "Attributes": {
          "agentC": "false"
        },
        "TargetContact": "Current"
      },
      "Identifier": "be655205-0b97-41e2-8da1-43c3b0d4c9b0",
      "Type": "UpdateContactAttributes",
      "Transitions": {
        "NextAction": "Survey FLow",
        "Errors": [
          {
            "NextAction": "Survey FLow",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ComparisonValue": "$.Attributes.Intent"
      },
      "Identifier": "TechSpot-HandOff",
      "Type": "Compare",
      "Transitions": {
        "NextAction": "be655205-0b97-41e2-8da1-43c3b0d4c9b0",
        "Conditions": [
          {
            "NextAction": "TechSpot_Handoff",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "Techspot - Teams Handoff"
              ]
            }
          },
          {
            "NextAction": "198a2484-f8fe-4d09-b80b-2b7336893aa1",
            "Condition": {
              "Operator": "TextContains",
              "Operands": [
                "Out of Scope"
              ]
            }
          },
          {
            "NextAction": "198a2484-f8fe-4d09-b80b-2b7336893aa1",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "Patient/Customer - Misroute"
              ]
            }
          },
          {
            "NextAction": "TechSpot_Handoff",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "Techspot - Other IT"
              ]
            }
          },
          {
            "NextAction": "198a2484-f8fe-4d09-b80b-2b7336893aa1",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "Unverified - Verification Failed"
              ]
            }
          }
        ],
        "Errors": [
          {
            "NextAction": "be655205-0b97-41e2-8da1-43c3b0d4c9b0",
            "ErrorType": "NoMatchingCondition"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "SSML": "$.FlowAttributes.TechSpot_Handoff"
      },
      "Identifier": "TechSpot_Handoff",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "198a2484-f8fe-4d09-b80b-2b7336893aa1",
        "Errors": [
          {
            "NextAction": "be655205-0b97-41e2-8da1-43c3b0d4c9b0",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "LambdaFunctionARN": "arn:aws:lambda:us-east-1:518902362956:function:SNOW_btsgsd-dev",
        "InvocationTimeLimitSeconds": "8",
        "InvocationType": "SYNCHRONOUS",
        "LambdaInvocationAttributes": {
          "caller_ani": "$.CustomerEndpoint.Address"
        },
        "ResponseValidation": {
          "ResponseType": "STRING_MAP"
        }
      },
      "Identifier": "Phone_Lookup",
      "Type": "InvokeLambdaFunction",
      "Transitions": {
        "NextAction": "Check_PhoneLookupStatus",
        "Errors": [
          {
            "NextAction": "Set_Lookup_Error",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ComparisonValue": "$.External.PhoneLookupStatus"
      },
      "Identifier": "Check_PhoneLookupStatus",
      "Type": "Compare",
      "Transitions": {
        "NextAction": "Set_Lookup_Error",
        "Conditions": [
          {
            "NextAction": "Set_Lookup_Matched",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "Matched"
              ]
            }
          },
          {
            "NextAction": "Set_Lookup_NotMatched",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "NotMatched"
              ]
            }
          }
        ],
        "Errors": [
          {
            "NextAction": "Set_Lookup_Error",
            "ErrorType": "NoMatchingCondition"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "SSML": "<speak>$.DataTables.LanguageCheck.Verify_Intro_Message</speak>"
      },
      "Identifier": "Verify_Intro_Message",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "Phone_Lookup",
        "Errors": [
          {
            "NextAction": "Phone_Lookup",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "Attributes": {
          "PhoneLookupStatus": "NotMatched",
          "OpeningPrompt": "Since I'm not able to verify you using your contact number, could you please tell me if you have your Abbvie UPI with you?"
        },
        "TargetContact": "Current"
      },
      "Identifier": "Set_Lookup_NotMatched",
      "Type": "UpdateContactAttributes",
      "Transitions": {
        "NextAction": "TopLevelBlocker_Message",
        "Errors": [
          {
            "NextAction": "TopLevelBlocker_Message",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "Attributes": {
          "OpeningPrompt": "Thanks $.Attributes.FirstName, you're all verified. How can I help you today?"
        },
        "TargetContact": "Current"
      },
      "Identifier": "Set_Lookup",
      "Type": "UpdateContactAttributes",
      "Transitions": {
        "NextAction": "TopLevelBlocker_Message",
        "Errors": [
          {
            "NextAction": "TopLevelBlocker_Message",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "Attributes": {
          "PhoneLookupStatus": "Error",
          "OpeningPrompt": "Since I'm not able to verify you using your contact number, could you please tell me if you have your Abbvie UPI with you?"
        },
        "TargetContact": "Current"
      },
      "Identifier": "Set_Lookup_Error",
      "Type": "UpdateContactAttributes",
      "Transitions": {
        "NextAction": "TopLevelBlocker_Message",
        "Errors": [
          {
            "NextAction": "TopLevelBlocker_Message",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "SSML": "<speak>$.DataTables.LanguageCheck.Bot_Outage_Message</speak>"
      },
      "Identifier": "Tech_Failure_Message",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "ff4ce28b-f76a-430a-ba3f-b5bf60cdfb94",
        "Errors": [
          {
            "NextAction": "ff4ce28b-f76a-430a-ba3f-b5bf60cdfb94",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ComparisonValue": "$.Attributes.region"
      },
      "Identifier": "region_check",
      "Type": "Compare",
      "Transitions": {
        "NextAction": "Escalate",
        "Conditions": [
          {
            "NextAction": "LATAM_Queue",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "LATAM"
              ]
            }
          }
        ],
        "Errors": [
          {
            "NextAction": "Escalate",
            "ErrorType": "NoMatchingCondition"
          }
        ]
      }
    },
    {
      "Parameters": {},
      "Identifier": "627c5ca8-9b09-4092-8b60-47aee2cb9ed6",
      "Type": "TransferContactToQueue",
      "Transitions": {
        "NextAction": "041ad0bc-26e4-414f-b8e2-efdc80f0f5e8",
        "Errors": [
          {
            "NextAction": "Queue_Unavailable_Message",
            "ErrorType": "QueueAtCapacity"
          },
          {
            "NextAction": "041ad0bc-26e4-414f-b8e2-efdc80f0f5e8",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "SSML": "<speak>$.DataTables.LanguageCheck.Queue_Unavailable_Message</speak>"
      },
      "Identifier": "Queue_Unavailable_Message",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "041ad0bc-26e4-414f-b8e2-efdc80f0f5e8",
        "Errors": [
          {
            "NextAction": "041ad0bc-26e4-414f-b8e2-efdc80f0f5e8",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {},
      "Identifier": "041ad0bc-26e4-414f-b8e2-efdc80f0f5e8",
      "Type": "DisconnectParticipant",
      "Transitions": {}
    },
    {
      "Parameters": {
        "LambdaFunctionARN": "arn:aws:lambda:us-east-1:518902362956:function:silence_guard-dev",
        "InvocationTimeLimitSeconds": "8",
        "InvocationType": "SYNCHRONOUS",
        "LambdaInvocationAttributes": {
          "ExpectedTool": "Complete",
          "Tool": "$.Attributes.Tool",
          "Intent": "$.Attributes.Intent",
          "CallSummary": "$.Attributes.CallSummary",
          "VerificationStatus": "$.Attributes.VerificationStatus",
          "VerifiedVia": "$.Attributes.VerifiedVia",
          "RoutingIntent": "$.Attributes.RoutingIntent",
          "ContactId": "$.ContactId",
          "reason": "$.Lex.SessionAttributes.reason",
          "region": "$.Attributes.region"
        },
        "ResponseValidation": {
          "ResponseType": "STRING_MAP"
        }
      },
      "Identifier": "Guard_Lambda_Complete",
      "Type": "InvokeLambdaFunction",
      "Transitions": {
        "NextAction": "Guard_Decision_Complete",
        "Errors": [
          {
            "NextAction": "Guard_Decision_Complete",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ComparisonValue": "$.Attributes.Intent"
      },
      "Identifier": "Tech_Failure_Check",
      "Type": "Compare",
      "Transitions": {
        "NextAction": "Silent_Route_Check",
        "Conditions": [
          {
            "NextAction": "Tech_Failure_Message",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "Unverified - Lookup Error"
              ]
            }
          }
        ],
        "Errors": [
          {
            "NextAction": "Silent_Route_Check",
            "ErrorType": "NoMatchingCondition"
          }
        ]
      }
    },
    {
      "Parameters": {
        "VoiceBehavior": {
          "VoiceRecordingBehavior": {
            "RecordedParticipants": [
              "Agent",
              "Customer"
            ],
            "IVRRecordingBehavior": "Enabled"
          },
          "VoiceAnalyticsBehavior": {
            "Enabled": "True",
            "AnalyticsLanguage": "$.Attributes.language_name",
            "AnalyticsModes": [
              "RealTime",
              "AutomatedInteraction"
            ],
            "ConversationalAnalyticsRedactionConfiguration": {
              "Enabled": "True",
              "RedactionMaskMode": "PII",
              "RedactionResults": "RedactedAndOriginal"
            },
            "SentimentConfiguration": {
              "Enabled": "True"
            },
            "SummaryConfiguration": {
              "SummaryModes": [
                "PostContact",
                "AutomatedInteraction"
              ]
            }
          }
        }
      },
      "Identifier": "19197f54-b210-41e2-8f4c-8f86a2c11dad",
      "Type": "UpdateContactRecordingAndAnalyticsBehavior",
      "Transitions": {
        "NextAction": "Set voice",
        "Errors": [
          {
            "NextAction": "Set voice",
            "ErrorType": "NoMatchingError"
          },
          {
            "NextAction": "Set voice",
            "ErrorType": "ChannelMismatch"
          }
        ]
      }
    },
    {
      "Parameters": {
        "Attributes": {
          "language_name": "en-US"
        },
        "TargetContact": "Current"
      },
      "Identifier": "3f3dbe3b-6046-4b02-b0b1-7b8502436f52",
      "Type": "UpdateContactAttributes",
      "Transitions": {
        "NextAction": "Welcome_Greeting",
        "Errors": [
          {
            "NextAction": "Welcome_Greeting",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "MetricType": "NumberOfAgentsOnline",
        "QueueId": "$.Queue.ARN"
      },
      "Identifier": "f998f5e7-eb1b-4011-95f1-af7f8b72997a",
      "Type": "CheckMetricData",
      "Transitions": {
        "NextAction": "error_message_2",
        "Conditions": [
          {
            "NextAction": "Survey Announcement",
            "Condition": {
              "Operator": "NumberGreaterThan",
              "Operands": [
                "0"
              ]
            }
          }
        ],
        "Errors": [
          {
            "NextAction": "Survey Announcement",
            "ErrorType": "NoMatchingCondition"
          },
          {
            "NextAction": "error_message_2",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "QueueId": "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/queue/f3cb5e84-218c-4575-bfef-7bc8635215fc"
      },
      "Identifier": "LATAM_Queue",
      "Type": "UpdateContactTargetQueue",
      "Transitions": {
        "NextAction": "1e776648-1130-4181-91e3-f5b531154afe",
        "Errors": [
          {
            "NextAction": "error_message_2",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "EventHooks": {
          "CustomerQueue": "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/contact-flow/cb5f9c2f-a0a3-4f42-a865-fc22d872938c"
        }
      },
      "Identifier": "b69a2aad-6fef-4349-a839-e1fbf206f2d3",
      "Type": "UpdateContactEventHooks",
      "Transitions": {
        "NextAction": "f998f5e7-eb1b-4011-95f1-af7f8b72997a",
        "Errors": [
          {
            "NextAction": "error_message_2",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "LambdaFunctionARN": "arn:aws:lambda:us-east-1:518902362956:function:conversionOfQueueMetrics-dev",
        "InvocationTimeLimitSeconds": "7",
        "InvocationType": "SYNCHRONOUS",
        "LambdaInvocationAttributes": {
          "invocationType": "putQueue"
        },
        "ResponseValidation": {
          "ResponseType": "STRING_MAP"
        }
      },
      "Identifier": "0323e84a-b89e-466c-bd65-aa96cf580f9d",
      "Type": "InvokeLambdaFunction",
      "Transitions": {
        "NextAction": "b69a2aad-6fef-4349-a839-e1fbf206f2d3",
        "Errors": [
          {
            "NextAction": "error_message_2",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "Attributes": {
          "Customer_Prefferred_Language": "$.Attributes.Customer_Prefferred_Language",
          "V2V_agentLanguage": "$.DataTables.LangConfig.language_code",
          "V2V_customerVoiceId": "$.DataTables.LangConfig.amazon_voice",
          "V2V_pollyEngine": "neural"
        },
        "TargetContact": "Current"
      },
      "Identifier": "1e776648-1130-4181-91e3-f5b531154afe",
      "Type": "UpdateContactAttributes",
      "Transitions": {
        "NextAction": "0323e84a-b89e-466c-bd65-aa96cf580f9d",
        "Errors": [
          {
            "NextAction": "error_message_2",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "QueueId": "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/queue/bc8a6c27-3e2c-4c2f-a1ee-5aaad1c7bbc7"
      },
      "Identifier": "Escalate",
      "Type": "UpdateContactTargetQueue",
      "Transitions": {
        "NextAction": "1e776648-1130-4181-91e3-f5b531154afe",
        "Errors": [
          {
            "NextAction": "error_message_2",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "SSML": "<speak>$.DataTables.LanguageCheck.error_message_2</speak>"
      },
      "Identifier": "error_message_2",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "f727499b-f040-4392-b1bd-a46af3bc15ce",
        "Errors": [
          {
            "NextAction": "f727499b-f040-4392-b1bd-a46af3bc15ce",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {},
      "Identifier": "f727499b-f040-4392-b1bd-a46af3bc15ce",
      "Type": "DisconnectParticipant",
      "Transitions": {}
    },
    {
      "Parameters": {
        "ComparisonValue": "$.Attributes.region"
      },
      "Identifier": "LATAM_Silent_Check",
      "Type": "Compare",
      "Transitions": {
        "NextAction": "Guard_Lambda_Escalate",
        "Conditions": [
          {
            "NextAction": "Routing_check",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "LATAM"
              ]
            }
          }
        ],
        "Errors": [
          {
            "NextAction": "Guard_Lambda_Escalate",
            "ErrorType": "NoMatchingCondition"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ComparisonValue": "$.External.GuardAllowed"
      },
      "Identifier": "Guard_Decision_Escalate",
      "Type": "Compare",
      "Transitions": {
        "NextAction": "Routing_check",
        "Conditions": [
          {
            "NextAction": "Routing_check",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "true"
              ]
            }
          },
          {
            "NextAction": "Guard_Recovery_Message",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "false"
              ]
            }
          }
        ],
        "Errors": [
          {
            "NextAction": "Routing_check",
            "ErrorType": "NoMatchingCondition"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ComparisonValue": "$.Attributes.RoutingIntent"
      },
      "Identifier": "Silent_Route_Check",
      "Type": "Compare",
      "Transitions": {
        "NextAction": "Guard_Lambda_Escalate",
        "Conditions": [
          {
            "NextAction": "Routing_check",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "FieldForce"
              ]
            }
          },
          {
            "NextAction": "LATAM_Silent_Check",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "Veeva"
              ]
            }
          },
          {
            "NextAction": "LATAM_Silent_Check",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "Medcom"
              ]
            }
          }
        ],
        "Errors": [
          {
            "NextAction": "Guard_Lambda_Escalate",
            "ErrorType": "NoMatchingCondition"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ThirdPartyPhoneNumber": "$.Attributes.hr_contact",
        "ThirdPartyConnectionTimeLimitSeconds": "30",
        "ContinueFlowExecution": "False",
        "CallerId": {
          "Name": "HR_Query"
        }
      },
      "Identifier": "HR_Helpdesk",
      "Type": "TransferParticipantToThirdParty",
      "Transitions": {
        "NextAction": "playprompt_1",
        "Errors": [
          {
            "NextAction": "playprompt_1",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "SSML": "$.FlowAttributes.hr_transfer"
      },
      "Identifier": "hr_Transfer",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "HR_Helpdesk",
        "Errors": [
          {
            "NextAction": "HR_Helpdesk",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ThirdPartyPhoneNumber": "$.Attributes.medcom_contact",
        "ThirdPartyConnectionTimeLimitSeconds": "30",
        "ContinueFlowExecution": "False",
        "CallerId": {
          "Name": "MedCome_Helpdesk"
        }
      },
      "Identifier": "MedCom_Helpdesk",
      "Type": "TransferParticipantToThirdParty",
      "Transitions": {
        "NextAction": "playprompt_1",
        "Errors": [
          {
            "NextAction": "playprompt_1",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "Text": "Por favor mantengase en la línea. su llamada será transferida al equipo de suporte de medcom en breve."
      },
      "Identifier": "Medcom_Transfer",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "MedCom_Helpdesk",
        "Errors": [
          {
            "NextAction": "MedCom_Helpdesk",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "SSML": "<speak>$.DataTables.LanguageCheck.playprompt_1</speak>"
      },
      "Identifier": "playprompt_1",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "ff4ce28b-f76a-430a-ba3f-b5bf60cdfb94",
        "Errors": [
          {
            "NextAction": "ff4ce28b-f76a-430a-ba3f-b5bf60cdfb94",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ThirdPartyPhoneNumber": "$.Attributes.veeva_contact",
        "ThirdPartyConnectionTimeLimitSeconds": "30",
        "ContinueFlowExecution": "False",
        "CallerId": {
          "Name": "Veeva_Helpdesk"
        }
      },
      "Identifier": "Veeva_Helpdesk",
      "Type": "TransferParticipantToThirdParty",
      "Transitions": {
        "NextAction": "playprompt_1",
        "Errors": [
          {
            "NextAction": "playprompt_1",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "Text": "Gracias por llamar al centro de atención al cliente de Abbvie front office application. Esta llamada puede ser monitorizada o grabada con fines de garantizar la calidad del servicio y para formación."
      },
      "Identifier": "Veeva_transfer",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "Veeva_Helpdesk",
        "Errors": [
          {
            "NextAction": "Veeva_Helpdesk",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "SSML": "<speak>$.DataTables.LanguageCheck.Welcome_Greeting</speak>"
      },
      "Identifier": "Welcome_Greeting",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "Verify_Intro_Message",
        "Errors": [
          {
            "NextAction": "Verify_Intro_Message",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ComparisonValue": "$.Attributes.RoutingIntent"
      },
      "Identifier": "Routing_check",
      "Type": "Compare",
      "Transitions": {
        "NextAction": "LiveAgent_Line_Check",
        "Conditions": [
          {
            "NextAction": "hr_Transfer",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "HR"
              ]
            }
          },
          {
            "NextAction": "FF_Verified_Check",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "FieldForce"
              ]
            }
          },
          {
            "NextAction": "Veeva_transfer",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "Veeva"
              ]
            }
          },
          {
            "NextAction": "Medcom_Transfer",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "Medcom"
              ]
            }
          }
        ],
        "Errors": [
          {
            "NextAction": "LiveAgent_Line_Check",
            "ErrorType": "NoMatchingCondition"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ThirdPartyPhoneNumber": "+18447706126",
        "ThirdPartyConnectionTimeLimitSeconds": "30",
        "ContinueFlowExecution": "False",
        "CallerId": {
          "Name": "FieldForce_Query"
        }
      },
      "Identifier": "FieldForce_Helpdesk",
      "Type": "TransferParticipantToThirdParty",
      "Transitions": {
        "NextAction": "playprompt_1",
        "Errors": [
          {
            "NextAction": "playprompt_1",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "SSML": "<speak>$.DataTables.LanguageCheck.FieldForce_Transfer</speak>"
      },
      "Identifier": "FieldForce_Transfer",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "FieldForce_Helpdesk",
        "Errors": [
          {
            "NextAction": "FieldForce_Helpdesk",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "FlowAttributes": {
          "surveyAnnouncement": {
            "Value": "<speak>$.DataTables.LanguageCheck.surveyAnnouncement</speak>"
          },
          "TechSpot_Handoff": {
            "Value": "<speak>$.DataTables.LanguageCheck.TechSpot_Handoff</speak>"
          },
          "hr_transfer": {
            "Value": "<speak>$.DataTables.LanguageCheck.hr_Transfer</speak>"
          }
        }
      },
      "Identifier": "f386788a-82c6-4075-86bb-20da1068f52b",
      "Type": "UpdateFlowAttributes",
      "Transitions": {
        "NextAction": "Welcome_Greeting",
        "Errors": [
          {
            "NextAction": "Welcome_Greeting",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "DataTableId": "0c2359aa-9062-43ec-9d0d-abc5861c2197",
        "Queries": [
          {
            "QueryName": "LanguageCheck",
            "Attributes": [
              "Welcome_Greeting",
              "Guard_Recovery_Message",
              "Verify_Intro_Message",
              "error_message_2",
              "FieldForce_Transfer",
              "Bot_Outage_Message",
              "playprompt_1",
              "Queue_Unavailable_Message",
              "TechSpot_Handoff",
              "surveyAnnouncement",
              "hr_Transfer",
              "ff_unverified_message",
              "liveAgent_transfer_message"
            ],
            "PrimaryValues": [
              {
                "AttributeName": "Language",
                "Value": "$.Attributes.language_name"
              }
            ]
          }
        ]
      },
      "Identifier": "430a3acf-25ed-45c4-bcd5-4741bb2c619c",
      "Type": "EvaluateDataTableValues",
      "Transitions": {
        "NextAction": "f386788a-82c6-4075-86bb-20da1068f52b",
        "Errors": [
          {
            "NextAction": "f386788a-82c6-4075-86bb-20da1068f52b",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ComparisonValue": "$.Attributes.VerificationStatus"
      },
      "Identifier": "FF_Verified_Check",
      "Type": "Compare",
      "Transitions": {
        "NextAction": "ff_unverified_message",
        "Conditions": [
          {
            "NextAction": "FieldForce_Transfer",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "Authenticated"
              ]
            }
          }
        ],
        "Errors": [
          {
            "NextAction": "ff_unverified_message",
            "ErrorType": "NoMatchingCondition"
          }
        ]
      }
    },
    {
      "Parameters": {},
      "Identifier": "198a2484-f8fe-4d09-b80b-2b7336893aa1",
      "Type": "DisconnectParticipant",
      "Transitions": {}
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "SSML": "<speak>$.DataTables.LanguageCheck.ff_unverified_message</speak>\n"
      },
      "Identifier": "ff_unverified_message",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "198a2484-f8fe-4d09-b80b-2b7336893aa1",
        "Errors": [
          {
            "NextAction": "FF_Unverified_Fallback",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "Text": "I'm sorry, as I couldn't verify your identity, I'm not able to help with that on this call. Please call back with your Abbvie UPI available. Thank you for calling the Abbvie Service Desk. Have a nice day. Goodbye."
      },
      "Identifier": "FF_Unverified_Fallback",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "198a2484-f8fe-4d09-b80b-2b7336893aa1",
        "Errors": [
          {
            "NextAction": "198a2484-f8fe-4d09-b80b-2b7336893aa1",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ComparisonValue": "$.Attributes.Intent"
      },
      "Identifier": "LiveAgent_Line_Check",
      "Type": "Compare",
      "Transitions": {
        "NextAction": "ff4ce28b-f76a-430a-ba3f-b5bf60cdfb94",
        "Conditions": [
          {
            "NextAction": "liveAgent_transfer_message",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "Veeva - Live Agent"
              ]
            }
          },
          {
            "NextAction": "liveAgent_transfer_message",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "Medcom - Live Agent"
              ]
            }
          }
        ],
        "Errors": [
          {
            "NextAction": "ff4ce28b-f76a-430a-ba3f-b5bf60cdfb94",
            "ErrorType": "NoMatchingCondition"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "SSML": "<speak>$.DataTables.LanguageCheck.liveAgent_transfer_message/speak>\n\n\n"
      },
      "Identifier": "liveAgent_transfer_message",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "ff4ce28b-f76a-430a-ba3f-b5bf60cdfb94",
        "Errors": [
          {
            "NextAction": "LiveAgent_Transfer_Fallback",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "Text": "Thanks - I'll connect you with a live agent who can help with that. Please stay on the line."
      },
      "Identifier": "LiveAgent_Transfer_Fallback",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "ff4ce28b-f76a-430a-ba3f-b5bf60cdfb94",
        "Errors": [
          {
            "NextAction": "ff4ce28b-f76a-430a-ba3f-b5bf60cdfb94",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "DataTableId": "6c35e399-f3dc-49d1-bcae-e893e7dcc261",
        "Queries": [
          {
            "QueryName": "TLBM",
            "Attributes": [
              "toplevelblocker_message"
            ],
            "PrimaryValues": [
              {
                "AttributeName": "system_phonenumber",
                "Value": "$.SystemEndpoint.Address"
              }
            ]
          }
        ]
      },
      "Identifier": "TopLevelBlocker_Message",
      "Type": "EvaluateDataTableValues",
      "Transitions": {
        "NextAction": "b328f7b4-744f-4984-beb0-d270528bc8f6",
        "Errors": [
          {
            "NextAction": "Connect assistant",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "Text": "$.DataTables.TLBM.toplevelblocker_message"
      },
      "Identifier": "b328f7b4-744f-4984-beb0-d270528bc8f6",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "Connect assistant",
        "Errors": [
          {
            "NextAction": "Connect assistant",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "Attributes": {
          "bot_retry": "1",
          "OpeningPrompt": "Sorry, could you say that again?"
        },
        "TargetContact": "Current"
      },
      "Identifier": "Bot_Retry_Set",
      "Type": "UpdateContactAttributes",
      "Transitions": {
        "NextAction": "Update session data",
        "Errors": [
          {
            "NextAction": "Bot_Outage_Message",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "LambdaFunctionARN": "arn:aws:lambda:us-east-1:518902362956:function:UpdateSessionAttributes-dev",
        "InvocationTimeLimitSeconds": "8",
        "InvocationType": "SYNCHRONOUS",
        "LambdaInvocationAttributes": {
          "language_name": "$.Attributes.language_name",
          "CallerAni": "$.CustomerEndpoint.Address",
          "ContactId": "$.ContactId",
          "PhoneLookupStatus": "$.Attributes.PhoneLookupStatus",
          "FirstName": "$.Attributes.FirstName",
          "LastName": "$.Attributes.LastName",
          "UPI": "$.Attributes.UPI",
          "UserId": "$.Attributes.UserId",
          "Email": "$.Attributes.Email",
          "FieldForce": "$.Attributes.FieldForce",
          "Active": "$.Attributes.Active",
          "UserStatus": "$.Attributes.UserStatus",
          "Region": "$.Attributes.region"
        },
        "ResponseValidation": {
          "ResponseType": "STRING_MAP"
        }
      },
      "Identifier": "Update session data",
      "Type": "InvokeLambdaFunction",
      "Transitions": {
        "NextAction": "Session_Update_Status_Check",
        "Errors": [
          {
            "NextAction": "Bot_Outage_Message",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ComparisonValue": "$.External.status"
      },
      "Identifier": "Session_Update_Status_Check",
      "Type": "Compare",
      "Transitions": {
        "NextAction": "Bot_Outage_Message",
        "Conditions": [
          {
            "NextAction": "Get customer input-L4Nj72lYly",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "success"
              ]
            }
          }
        ],
        "Errors": [
          {
            "NextAction": "Bot_Outage_Message",
            "ErrorType": "NoMatchingCondition"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ComparisonValue": "$.Attributes.bot_retry"
      },
      "Identifier": "Bot_Retry_Check",
      "Type": "Compare",
      "Transitions": {
        "NextAction": "Bot_Retry_Set",
        "Conditions": [
          {
            "NextAction": "Bot_Outage_Message",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "1"
              ]
            }
          }
        ],
        "Errors": [
          {
            "NextAction": "Bot_Retry_Set",
            "ErrorType": "NoMatchingCondition"
          }
        ]
      }
    },
    {
      "Parameters": {
        "Attributes": {
          "Tool": "$.Lex.SessionAttributes.Tool",
          "Customer_Prefferred_Language": "$.Lex.SessionAttributes.LanguageDetected",
          "RoutingIntent": "$.Lex.SessionAttributes.RoutingIntent",
          "CallSummary": "$.Lex.SessionAttributes.CallSummary",
          "ScreenPopURL": "$.Lex.SessionAttributes.ScreenPopURL",
          "Intent": "$.Lex.SessionAttributes.Intent",
          "VerificationStatus": "$.Lex.SessionAttributes.VerificationStatus",
          "VerifiedVia": "$.Lex.SessionAttributes.VerifiedVia",
          "CallerName": "$.Lex.SessionAttributes.CallerName",
          "UPI": "$.Lex.SessionAttributes.UPI",
          "UserId": "$.Lex.SessionAttributes.UserId",
          "UserStatus": "$.Lex.SessionAttributes.UserStatus",
          "Email": "$.Lex.SessionAttributes.Email",
          "Dialed_Number": "$.SystemEndpoint.Address"
        },
        "TargetContact": "Current"
      },
      "Identifier": "a6683a59-32ab-4db9-bad1-65a1f93f0b5e",
      "Type": "UpdateContactAttributes",
      "Transitions": {
        "NextAction": "ca48f6f9-347e-4b45-a9cc-43c5c5a4d5fa",
        "Errors": [
          {
            "NextAction": "ca48f6f9-347e-4b45-a9cc-43c5c5a4d5fa",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "Attributes": {
          "IVR_Prefferred_Language": "$.Attributes.Customer_Prefferred_Language"
        },
        "TargetContact": "Current"
      },
      "Identifier": "3b2f7d60-f6c2-48fd-885c-27bf7377c204",
      "Type": "UpdateContactAttributes",
      "Transitions": {
        "NextAction": "Check contact attributes",
        "Errors": [
          {
            "NextAction": "Check contact attributes",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ComparisonValue": "$.Attributes.Tool"
      },
      "Identifier": "Check contact attributes",
      "Type": "Compare",
      "Transitions": {
        "NextAction": "Bot_Retry_Check",
        "Conditions": [
          {
            "NextAction": "Tech_Failure_Check",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "Escalate"
              ]
            }
          },
          {
            "NextAction": "Guard_Lambda_Complete",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "Complete"
              ]
            }
          }
        ],
        "Errors": [
          {
            "NextAction": "Bot_Retry_Check",
            "ErrorType": "NoMatchingCondition"
          }
        ]
      }
    },
    {
      "Parameters": {
        "ComparisonValue": "$.Attributes.Customer_Prefferred_Language"
      },
      "Identifier": "ca48f6f9-347e-4b45-a9cc-43c5c5a4d5fa",
      "Type": "Compare",
      "Transitions": {
        "NextAction": "16190622-3ff4-4f25-9840-c54b23d24eab",
        "Conditions": [
          {
            "NextAction": "3b2f7d60-f6c2-48fd-885c-27bf7377c204",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "en-US"
              ]
            }
          },
          {
            "NextAction": "3b2f7d60-f6c2-48fd-885c-27bf7377c204",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "es-MX"
              ]
            }
          },
          {
            "NextAction": "3b2f7d60-f6c2-48fd-885c-27bf7377c204",
            "Condition": {
              "Operator": "Equals",
              "Operands": [
                "pt-BR"
              ]
            }
          }
        ],
        "Errors": [
          {
            "NextAction": "16190622-3ff4-4f25-9840-c54b23d24eab",
            "ErrorType": "NoMatchingCondition"
          }
        ]
      }
    },
    {
      "Parameters": {
        "Attributes": {
          "IVR_Prefferred_Language": "$.Attributes.language_name"
        },
        "TargetContact": "Current"
      },
      "Identifier": "16190622-3ff4-4f25-9840-c54b23d24eab",
      "Type": "UpdateContactAttributes",
      "Transitions": {
        "NextAction": "Check contact attributes",
        "Errors": [
          {
            "NextAction": "Check contact attributes",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "EventHooks": {
          "DefaultAgentUI": "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/contact-flow/8789bfcd-42dd-4060-ac31-f3279dd089a5"
        }
      },
      "Identifier": "ff4ce28b-f76a-430a-ba3f-b5bf60cdfb94",
      "Type": "UpdateContactEventHooks",
      "Transitions": {
        "NextAction": "region_check",
        "Errors": [
          {
            "NextAction": "region_check",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "SSML": "<speak>$.DataTables.LanguageCheck.Bot_Outage_Message</speak>"
      },
      "Identifier": "Bot_Outage_Message",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "Set_Outage_Attributes",
        "Errors": [
          {
            "NextAction": "Set_Outage_Attributes",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "Attributes": {
          "Tool": "Escalate",
          "Intent": "System - Bot Unavailable",
          "CallSummary": "Bot unavailable - caller transferred without AI triage",
          "VerificationStatus": "Unauthenticated",
          "VerifiedVia": "Unverified",
          "Dialed_Number": "$.SystemEndpoint.Address",
          "IVR_Prefferred_Language": "$.Attributes.language_name"
        },
        "TargetContact": "Current"
      },
      "Identifier": "Set_Outage_Attributes",
      "Type": "UpdateContactAttributes",
      "Transitions": {
        "NextAction": "ff4ce28b-f76a-430a-ba3f-b5bf60cdfb94",
        "Errors": [
          {
            "NextAction": "ff4ce28b-f76a-430a-ba3f-b5bf60cdfb94",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "SkipWhenDTMFBufferEnabled": "false",
        "SSML": "$.FlowAttributes.surveyAnnouncement"
      },
      "Identifier": "Survey Announcement",
      "Type": "MessageParticipant",
      "Transitions": {
        "NextAction": "d6d76975-d765-4cf9-a4af-136504b2ac12",
        "Errors": [
          {
            "NextAction": "d6d76975-d765-4cf9-a4af-136504b2ac12",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "EventHooks": {
          "CustomerRemaining": "arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d/contact-flow/e2bea420-1eb7-436e-a339-9add640158db"
        }
      },
      "Identifier": "d9899688-e08c-4865-a827-2d22da50eb82",
      "Type": "UpdateContactEventHooks",
      "Transitions": {
        "NextAction": "627c5ca8-9b09-4092-8b60-47aee2cb9ed6",
        "Errors": [
          {
            "NextAction": "627c5ca8-9b09-4092-8b60-47aee2cb9ed6",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "Attributes": {
          "agentC": "true"
        },
        "TargetContact": "Current"
      },
      "Identifier": "d6d76975-d765-4cf9-a4af-136504b2ac12",
      "Type": "UpdateContactAttributes",
      "Transitions": {
        "NextAction": "d9899688-e08c-4865-a827-2d22da50eb82",
        "Errors": [
          {
            "NextAction": "d9899688-e08c-4865-a827-2d22da50eb82",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "Attributes": {
          "country": "$.DataTables.LangConfig.country",
          "hr_contact": "$.DataTables.LangConfig.hr_contact",
          "language_name": "$.DataTables.LangConfig.language_code",
          "region": "$.DataTables.LangConfig.region",
          "veeva_contact": "$.DataTables.LangConfig.veeva_contact",
          "medcom_contact": "$.DataTables.LangConfig.medcom_contact",
          "amazon_voice": "$.DataTables.LangConfig.amazon_voice",
          "language": "$.DataTables.LangConfig.language_name"
        },
        "TargetContact": "Current"
      },
      "Identifier": "dd7a2a0c-425f-49c5-a9e4-1251df5e2fe0",
      "Type": "UpdateContactAttributes",
      "Transitions": {
        "NextAction": "19197f54-b210-41e2-8f4c-8f86a2c11dad",
        "Errors": [
          {
            "NextAction": "19197f54-b210-41e2-8f4c-8f86a2c11dad",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "VoiceBehavior": {
          "VoiceRecordingBehavior": {
            "RecordedParticipants": [
              "Agent",
              "Customer"
            ],
            "IVRRecordingBehavior": "Enabled"
          },
          "VoiceAnalyticsBehavior": {
            "Enabled": "True",
            "AnalyticsLanguage": "en-US",
            "AnalyticsModes": [
              "RealTime",
              "AutomatedInteraction"
            ],
            "ConversationalAnalyticsRedactionConfiguration": {
              "Enabled": "True",
              "RedactionMaskMode": "PII",
              "RedactionResults": "RedactedAndOriginal"
            },
            "SentimentConfiguration": {
              "Enabled": "True"
            },
            "SummaryConfiguration": {
              "SummaryModes": [
                "PostContact",
                "AutomatedInteraction"
              ]
            }
          }
        }
      },
      "Identifier": "a928eec3-603d-4c37-bfe4-823cd653c0f3",
      "Type": "UpdateContactRecordingAndAnalyticsBehavior",
      "Transitions": {
        "NextAction": "Set voice_fallback",
        "Errors": [
          {
            "NextAction": "Set voice_fallback",
            "ErrorType": "NoMatchingError"
          },
          {
            "NextAction": "Set voice_fallback",
            "ErrorType": "ChannelMismatch"
          }
        ]
      }
    },
    {
      "Parameters": {
        "FlowLoggingBehavior": "Enabled"
      },
      "Identifier": "Set logging",
      "Type": "UpdateFlowLoggingBehavior",
      "Transitions": {
        "NextAction": "d1656116-cba5-4a8d-9178-355a48bfdcf3"
      }
    },
    {
      "Parameters": {
        "DataTableId": "8e9d51d1-20dc-4cd2-9693-6112949e3fb6",
        "Queries": [
          {
            "QueryName": "LangConfig",
            "Attributes": [
              "medcom_contact",
              "amazon_speaking_style",
              "amazon_voice",
              "country",
              "language_name",
              "veeva_contact",
              "region",
              "hr_contact",
              "language_code",
              "amazon_speaking_engine"
            ],
            "PrimaryValues": [
              {
                "AttributeName": "system_phonenumber",
                "Value": "$.SystemEndpoint.Address"
              }
            ]
          }
        ]
      },
      "Identifier": "Load lang config",
      "Type": "EvaluateDataTableValues",
      "Transitions": {
        "NextAction": "dd7a2a0c-425f-49c5-a9e4-1251df5e2fe0",
        "Errors": [
          {
            "NextAction": "a928eec3-603d-4c37-bfe4-823cd653c0f3",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    },
    {
      "Parameters": {
        "Attributes": {
          "OriginalContactId": "$.ContactId"
        },
        "TargetContact": "Current"
      },
      "Identifier": "d1656116-cba5-4a8d-9178-355a48bfdcf3",
      "Type": "UpdateContactAttributes",
      "Transitions": {
        "NextAction": "Load lang config",
        "Errors": [
          {
            "NextAction": "Load lang config",
            "ErrorType": "NoMatchingError"
          }
        ]
      }
    }
  ]
}

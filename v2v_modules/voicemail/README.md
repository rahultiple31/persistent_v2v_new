# voicemail (VMX3) module

Terraform-managed VMX3 voicemail stack for the V2V Connect instance
(`btsgsd-dev-v2v-poc-us-east-1`). Called from `environments/v2v-dev/main.tf` as
`module.voicemail`, stored in the `connect` state, deployed with the pipeline
choice `voicemail`.

Voicemails are delivered as **guided tasks** (copied from DEV-SSO). No IAM user
or access key is used: recording URLs are signed by the GuidedTaskPresigner
Lambda with its own role, when the agent opens the task.

## Flow of a voicemail

1. Caller records in flow module `BTSGSD-V2V-US-VMX3_Main_VM_Module` (sets `vmx3_mode = guided_task`; timestamp from `BTSGSD-V2V-US-voicemail-VoicemailTimestamper`).
2. Contact trace record -> Kinesis `BTSGSD-V2V-US-voiceMail` -> `RecordingProcessor` trims the IVR recording into `btsgsd-v2v-us-voicemail-recording`.
3. S3 event -> `BTSGSD-V2V-US-voicemail-TranscriberRule` -> `Transcriber` -> Amazon Transcribe -> `btsgsd-v2v-us-voicemail-transcript` (failures: `TranscribeErrorHandler`).
4. S3 event -> `BTSGSD-V2V-US-voicemail-PackagerRule` -> `Packager` starts a task with flow `BTSGSD-V2V-US-VMX3_Basic_Task_Flow`, storing `vmx3_recording_key`.
5. The task flow sets the agent UI hook to `BTSGSD-V2V-US-VMX3_Guided_Task_Flow`, which calls `GuidedTaskPresigner` (1-hour URL) and shows view `BTSGSD-V2V-US-Voicemail Task View` (player, transcript, caller details).

## Resources

| Type | Name |
| --- | --- |
| KMS key + alias | `alias/BTSGSD-V2V-US-voicemail` (buckets), `alias/BTSGSD-V2V-US-voicemail-kinesis` (stream) |
| S3 buckets | `btsgsd-v2v-us-voicemail-recording`, `btsgsd-v2v-us-voicemail-transcript` |
| Kinesis stream | `BTSGSD-V2V-US-voiceMail` (+ optional CTR and Agent Events storage configs) |
| IAM role + policy | `BTSGSD-V2V-US-voicemail-lambdaRole`, `..._customerManaged` |
| Lambda layer | `BTSGSD-V2V-US-VMX3-Python-Layer` |
| Lambdas | `BTSGSD-V2V-US-voicemail-` `VoicemailTimestamper`, `RecordingProcessor`, `Transcriber`, `TranscribeErrorHandler`, `GuidedTaskPresigner`, `Packager` |
| EventBridge rules | `BTSGSD-V2V-US-voicemail-PackagerRule`, `-TranscriberRule`, `-TranscribeErrorHandlerRule` |
| Lambda permissions (S3) | `Transcriber` and `Packager` from the transcript bucket (`AllowS3-TranscriptBucket`, QA requirement); bucket ARNs and account come from the module |
| Connect | Task flow, guided task flow, view, flow module; timestamper and guided presigner permissions + instance associations |

## Sources

- Lambda code: deployed `voicemail-v2v-*` functions; `GuidedTaskPresigner` from `VMX3-GuidedTaskPresigner-btsgsd-dev-us-east-1`.
- `assets/`: latest DEV-SSO exports (2026-11-05) of `VMX3_Basic_Task_Flow_btsgsd-dev-us-east-1`, `VMX3_Guided_Task_Flow_btsgsd-dev-us-east-1`, `VMX3_Main_VM_Module_btsgsd-dev-us-east-1` and view `Voicemail Task View`. `connect.tf` replaces every DEV-SSO reference (queue, prompt, data table, timestamper, customer queue flow, guided flow, view, presigner); preconditions fail on leftovers.
- Packager environment: `VMX3-Packager-btsgsd-dev-us-east-1` (guided-task mode, no presigner).
- Triggers: EventBridge (as in DEV-SSO). At the dev team's request (Nov 2026) the Transcriber and Packager also allow `s3.amazonaws.com` to invoke them from the transcript bucket (QA requirement; DEV-SSO scopes the Transcriber to its recordings bucket), scoped by `source_arn` and `source_account`; no S3 notification is configured, so EventBridge stays the only trigger.

## Retired (Nov 2026)

- User-key Presigner Lambda, its log group, secret `BTSGSD-V2V-US-voicemail` and the access key on `VMX3_Presigner_User_btsgsd-dev-us-east-1`: deleted by Terraform.
- Recordings bucket `btsgsd-v2v-us-voicemail`: replaced by `btsgsd-v2v-us-voicemail-recording`; deleted in two runs (`retired.tf`, variable `delete_retired_recordings_bucket`).
- Role permissions for SES, Secrets Manager and Lambda invoke: removed.

## Agent Events

`associate_agent_events_stream` (root: `voicemail_associate_agent_events_stream`) associates the same Kinesis stream with the instance's Agent Events. Connect allows one Agent Events association per instance: remove any console association before applying.

## Notes

- The view header loads an image from `raw.githubusercontent.com` (as in DEV-SSO); it does not render if agent browsers block that host.
- `presigned_url_expiry` is set as in DEV-SSO but not read by the code (URLs last 1 hour).
- `TranscribeErrorHandlerRule` matches every failed `vmx3_*` Transcribe job in the account (as in the original VMX3 deployment).

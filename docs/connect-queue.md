# Dev Connect queue

The `connect` selection creates `module.connect_queue[0]` in
`btsgsd-dev-us-east-1`, with these settings:

- Queue: `BTSGSD-DEV SSO-US-MAIN-QUEUE` (configurable through `queue_name`).
- Hours: `btsgsd-Dev-HoursOfOperation_EN_ES_PT`, every day from 12:00 AM to
  12:00 AM in `America/New_York`.
- Tags: `Env=Dev` and `Org=btsgsd`, plus the existing common tags.
- Quick connects: `FF Help Desk` and `HR Help Desk`, both dialing `+18557113853`.
- Outbound caller flow: the existing `Default outbound` flow in that instance.
- Outbound caller ID: the claimed phone-number UUID supplied through
  `outbound_phone_number_id`.

The placeholder `REPLACE_WITH_CLAIMED_PHONE_NUMBER_ID` remains in dev tfvars as
requested. Replace it with the actual Connect resource UUID before deployment.
The module rejects the placeholder and telephone-number text with a clear
precondition error; it does not invent an ID or claim another phone number.

With the pipeline AWS credentials available, retrieve the ID using:

```bash
aws connect list-phone-numbers-v2 \
  --target-arn arn:aws:connect:us-east-1:518902362956:instance/c227a737-3e4f-4c64-8397-2d37e318801d \
  --region us-east-1 \
  --query "ListPhoneNumbersSummaryList[?PhoneNumber=='+18557113853'].PhoneNumberId" \
  --output text
```

The Dev main inbound flow receives the managed queue ARN directly. Its explicit
`lookup_main_inbound_queue = false` setting avoids looking up a new queue before
it exists. Other callers of the Connect module keep the existing queue-name
lookup unless they supply a managed ARN and disable that lookup.

Run the pipeline from `main`, environment `dev`, and choose
`connect-queue` under Target module to target
`module.connect_queue` (queue, hours, quick connects and their dependencies).
This selection uses `enabled_modules=["connect"]` and the existing backend key
`terraform-state/dev/us-east-1/connect/terraform.tfstate`. It is Dev-only.
The `connect` selection also includes this queue in a full Connect deployment.
Review action `plan` before running action `apply`. The output `connect_queue`
contains the queue ARN/ID, hours ID and quick-connect IDs. Existing matching
resources must be imported into these module addresses before managing them;
the new module does not adopt or delete an existing queue automatically.

The inbound JSON's existing local edits are preserved. This module wires the
exported US main queue reference; other queues referenced by that JSON retain
their supplied routing destinations.

References: [Connect hours of operation](https://docs.aws.amazon.com/connect/latest/adminguide/set-hours-operation.html),
[list-phone-numbers-v2](https://docs.aws.amazon.com/cli/latest/reference/connect/list-phone-numbers-v2.html).

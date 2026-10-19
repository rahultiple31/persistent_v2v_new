# Amazon Connect queue

Creates a queue in an existing Connect instance, seven days of midnight-to-midnight
hours in `America/New_York`, and the phone quick connects `FF Help Desk` and
`HR Help Desk`, both dialing `+18557113853`.

The queue uses the existing `Default outbound` flow and a supplied claimed
phone-number resource UUID. The module does not claim a telephone number.
See [Dev deployment notes](../../docs/connect-queue.md).

# Customer-queue dependency resolution

The Connect module resolves the exported customer-queue flow's `PromptId`,
`DataTableId` and `FlowModuleId` against the target instance during Terraform
planning, or during apply when the instance is not known until then. It uses
read-only AWS CLI calls with the pipeline's existing OIDC credentials. The
source JSON is not modified, and the flow's actions, transitions and module
alias/version are preserved.

The current export expects these resources in Dev:

- Prompt: `CustomerQueueMOH`
- Data table: `BTSGSD-Survey-DataTable`
- Module: `VMX3_Main_VM_Module_abbvie-sd-contactcenter-dev-us`

Create/import any missing dependency before deploying the customer-queue flow.
If a dependency has a different Dev name, set an explicit mapping in the Dev
Terraform inputs, for example:

```hcl
connect_customer_queue_dependency_names = {
  "CustomerQueueMOH" = "YourActualDevPromptName"
}
```

The agent needs Python 3 and AWS CLI v2 with `connect list-data-tables` support.
The pipeline role needs `connect:ListPrompts`, `connect:ListDataTables` and
`connect:ListContactFlowModules` access for the target instance. Other references,
including Lex aliases and Lambda integrations, still need to be valid and
associated with that instance.

Run `terraform init`, then generate and review a fresh plan after changing the
inputs. Do not reuse the plan artifact from the failed deployment.

Resolver tests:

```bash
python3 -B -m unittest discover -s modules/connect/tests -p 'test_resolve_customer_queue_dependencies.py' -v
```

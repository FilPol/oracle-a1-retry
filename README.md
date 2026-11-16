# oracle-a1-retry

A GitHub Actions workflow that keeps retrying to launch an Oracle Cloud `VM.Standard.A1.Flex`
instance from an existing boot volume until the availability domain has free capacity
("Out of host capacity"). Once the instance exists, the workflow disables itself.

- `retry.sh` makes one launch attempt about every 3.5 minutes. It alternates between
  2 OCPU / 12 GB and 1 OCPU / 6 GB, and checks first that no instance with that name exists.
- `.github/workflows/a1-retry.yml` runs for about 50 minutes (the `minutes` input) and then starts
  the next run itself, so coverage is continuous. The hourly cron only restarts the chain if it
  ever breaks.

Everything account-specific comes from repository secrets: `OCI_KEY`, `OCI_USER`,
`OCI_FINGERPRINT`, `OCI_TENANCY`, `OCI_AD`, `OCI_SUBNET`, `OCI_BOOT_VOLUME` and `SSH_PUBKEY`.

When you're done, delete the repository and the OCI API key.

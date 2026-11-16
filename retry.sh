#!/usr/bin/env bash
# Retries launching an OCI VM.Standard.A1.Flex instance from an existing boot volume until the
# availability domain has free capacity again ("Out of host capacity"), then stops.
#
# Env (from GitHub secrets): OCI_TENANCY (also used as compartment), OCI_AD, OCI_SUBNET,
# OCI_BOOT_VOLUME, SSH_PUBKEY, INSTANCE_NAME (default claude-term), RUN_MINUTES (default 54).
# OCI auth comes from ~/.oci/config written by the workflow.
#
# One launch per round, alternating 2 OCPU/12 GB and 1 OCPU/6 GB (Always Free limit is 2/12;
# two launches seconds apart get HTTP 429). ~3.5 min between attempts.
# Writes launched=true|false to $GITHUB_OUTPUT.
set -u
export PYTHONWARNINGS=ignore SUPPRESS_LABEL_WARNING=True OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
NAME=${INSTANCE_NAME:-claude-term}
DEADLINE=$(( $(date +%s) + ${RUN_MINUTES:-54} * 60 ))
OUT=${GITHUB_OUTPUT:-/dev/null}
W=$(mktemp -d)

printf '{"sourceType":"bootVolume","bootVolumeId":"%s"}' "$OCI_BOOT_VOLUME" > "$W/source.json"
printf '{"ssh_authorized_keys":"%s"}' "$SSH_PUBKEY" > "$W/metadata.json"
shapes=('{"ocpus":2,"memoryInGBs":12}' '{"ocpus":1,"memoryInGBs":6}')
# Start each run on a different shape so both get tried even if runs are short.
n=$(( $(date +%H) % 2 ))

log() { echo "$(date -u +%H:%M:%S) $*"; }

alive() {
  oci compute instance list -c "$OCI_TENANCY" --display-name "$NAME" --all \
    --query 'data[?"lifecycle-state"!=`TERMINATED` && "lifecycle-state"!=`TERMINATING`].id | [0]' \
    --raw-output 2>/dev/null
}

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if [[ "$(alive)" == ocid1.instance* ]]; then
    log "an instance named $NAME already exists - done"
    echo "launched=true" >> "$OUT"; exit 0
  fi

  s=${shapes[$((n % 2))]}; n=$((n + 1))
  echo "$s" > "$W/shape.json"
  out=$(oci compute instance launch --availability-domain "$OCI_AD" -c "$OCI_TENANCY" \
    --display-name "$NAME" --shape VM.Standard.A1.Flex --shape-config "file://$W/shape.json" \
    --source-details "file://$W/source.json" --subnet-id "$OCI_SUBNET" --assign-public-ip true \
    --metadata "file://$W/metadata.json" --no-retry --query 'data."lifecycle-state"' --raw-output 2>&1)
  rc=$?
  flat=$(echo "$out" | tr -s '\n\t ' ' ')
  sleep_s=200
  if [ $rc -eq 0 ]; then
    log "LAUNCHED with shape $s (state: $flat)"
    echo "launched=true" >> "$OUT"; exit 0
  elif echo "$flat" | grep -qE 'Out of host capacity|Out of capacity|OutOfCapacity|InternalError'; then
    log "no capacity for $s"
  elif echo "$flat" | grep -qE 'TooManyRequests|"status": 429'; then
    log "rate limited (429) on $s"; sleep_s=600
  else
    # Only print the error code/message, never the request details.
    log "ERROR rc=$rc: $(echo "$out" | grep -E '"(code|message)"' | tr -s '\n\t ' ' ' | cut -c1-300)"
    sleep_s=300
  fi
  left=$(( DEADLINE - $(date +%s) ))
  [ "$left" -le "$sleep_s" ] && break
  sleep $(( sleep_s + RANDOM % 40 ))
done

log "no capacity this run - the next scheduled run continues"
echo "launched=false" >> "$OUT"

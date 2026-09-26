#!/bin/sh
# Starts the local Supabase stack from supabase/migrations (#41), retrying only when an image pull
# fails outright. The CI job pulls from public.ecr.aws (ghcr.io throttled on 2026-09-23), and ECR
# refuses pulls with "toomanyrequests" on some days too. The CLI retries each pull three times itself
# and only then fails with "failed to pull docker image", which is what this retries. Each retry keeps
# the images already pulled, so it has fewer to fetch. Any other failure fails at once. That includes
# a migration that fails to apply after the CLI recovered from a throttled pull. On PR #102 that case
# was retried when this matched "toomanyrequests" alone.
#
# Only the services the tests use are started: the database, auth, the REST API and its gateway.

exclude=studio,imgproxy,inbucket,mailpit,edge-runtime,logflare,vector,supavisor,storage-api,realtime,postgres-meta
cli="${SUPABASE_CLI:-npx --yes supabase@2.117.0}"
log=$(mktemp)

for attempt in 1 2 3 4 5; do
  echo "supabase start, attempt $attempt"
  $cli start -x "$exclude" >"$log" 2>&1
  status=$?
  cat "$log"
  [ "$status" -eq 0 ] && exit 0
  if ! grep -q 'failed to pull docker image' "$log"; then
    echo "supabase start failed (exit $status), and not on an image pull: not retrying"
    exit "$status"
  fi
  $cli stop --no-backup >/dev/null 2>&1
  [ "$attempt" -lt 5 ] && sleep $((attempt * 30))
done
echo "supabase start: every attempt failed to pull an image"
exit 1

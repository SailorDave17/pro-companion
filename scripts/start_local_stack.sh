#!/bin/sh
# Starts the local Supabase stack from supabase/migrations (#41), retrying only when an image pull is
# throttled. The CI job pulls from public.ecr.aws (ghcr.io throttled on 2026-09-23), and ECR refuses
# pulls with "toomanyrequests" on some days too. Each retry keeps the images already pulled, so it has
# fewer to fetch. Any other failure, a migration that fails to apply among them, fails at once.
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
  if ! grep -q toomanyrequests "$log"; then
    echo "supabase start failed (exit $status), and not on a throttled pull: not retrying"
    exit "$status"
  fi
  $cli stop --no-backup >/dev/null 2>&1
  [ "$attempt" -lt 5 ] && sleep $((attempt * 30))
done
echo "supabase start: every attempt was refused a pull (toomanyrequests)"
exit 1

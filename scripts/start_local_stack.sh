#!/bin/sh
# Starts the local Supabase stack from supabase/migrations (#41), retrying only when an image pull
# fails outright, and moving to another registry when one has stopped serving this runner (#140).
#
# The CLI retries each pull three times itself and only then fails with "failed to pull docker
# image", which is the only failure retried here. Any other failure fails at once. That includes a
# migration that fails to apply after the CLI recovered from a throttled pull. On PR #102 that case
# was retried when this matched "toomanyrequests" alone.
#
# Registries, in order: SUPABASE_INTERNAL_IMAGE_REGISTRY if set, else public.ecr.aws (ghcr.io
# throttled on 2026-09-23), then the others of public.ecr.aws, ghcr.io and docker.io.
# - A pull refused "Data limit exceeded" moves to the next registry at once. ECR's data limit held on
#   PR #138 (2026-10-20) through five attempts and a job re-run on a fresh runner, so retrying it is
#   spent time.
# - Any other refused pull ("Rate exceeded") retries the same registry with a backoff, up to three
#   attempts, since each attempt keeps the images already pulled. Then it moves on.
# - The registry that started the stack is written to $GITHUB_ENV when there is one, so the job's
#   later steps (db reset) name the same images instead of pulling from the refusing registry.
#
# Only the services the tests use are started: the database, auth, the REST API and its gateway.
# START_STACK_BACKOFF_S (default 30) scales the backoff; the script's test sets it to 0.

exclude=studio,imgproxy,inbucket,mailpit,edge-runtime,logflare,vector,supavisor,storage-api,realtime,postgres-meta
cli="${SUPABASE_CLI:-npx --yes supabase@2.117.0}"
backoff="${START_STACK_BACKOFF_S:-30}"
first="${SUPABASE_INTERNAL_IMAGE_REGISTRY:-public.ecr.aws}"
registries="$first"
for other in public.ecr.aws ghcr.io docker.io; do
  [ "$other" = "$first" ] || registries="$registries $other"
done
log=$(mktemp)

for registry in $registries; do
  for attempt in 1 2 3; do
    echo "supabase start from $registry, attempt $attempt"
    SUPABASE_INTERNAL_IMAGE_REGISTRY="$registry" $cli start -x "$exclude" >"$log" 2>&1
    status=$?
    cat "$log"
    if [ "$status" -eq 0 ]; then
      if [ -n "$GITHUB_ENV" ]; then
        echo "SUPABASE_INTERNAL_IMAGE_REGISTRY=$registry" >>"$GITHUB_ENV"
      fi
      echo "supabase start: started from $registry"
      exit 0
    fi
    if ! grep -q 'failed to pull docker image' "$log"; then
      echo "supabase start failed (exit $status), and not on an image pull: not retrying"
      exit "$status"
    fi
    SUPABASE_INTERNAL_IMAGE_REGISTRY="$registry" $cli stop --no-backup >/dev/null 2>&1
    if grep -q 'Data limit exceeded' "$log"; then
      echo "supabase start: $registry refused on its data limit, which a retry from this runner does not outlast"
      break
    fi
    [ "$attempt" -lt 3 ] && sleep $((attempt * backoff))
  done
done
echo "supabase start: every registry failed to pull an image ($registries)"
exit 1

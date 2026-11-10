#!/bin/bash
# Temporary, user-session test runner. The controller writes a SHA-256 manifest
# only after publishing its numbered script. No service or login item is added.
set -u
base=${1:?HTTP control directory required}
result=${2:?HTTP results prefix required}
work=$(mktemp -d /tmp/henge-command-runner.XXXXXX)
began=$SECONDS
last=0
report() { printf '%s\n' "$*" | curl -fsS --max-time 10 --data-binary @- "$result-state.txt" >/dev/null; }
report "runner=$$ status=ready work=$work"
while [ "$((SECONDS-began))" -lt 7200 ]; do
  manifest=$(curl -fsS --max-time 10 "$base/index" 2>/dev/null) || { sleep 2; continue; }
  [ "$manifest" != stop ] || break
  read -r id sha deadline <<< "$manifest"
  if ! [[ ${id:-} =~ ^[0-9]{1,6}$ && ${sha:-} =~ ^[0-9a-f]{64}$ && ${deadline:-} =~ ^[0-9]{1,4}$ ]]; then sleep 2; continue; fi
  if [ "$id" -le "$last" ] || [ "$deadline" -lt 1 ] || [ "$deadline" -gt 3600 ]; then sleep 2; continue; fi
  file="$work/job-$id.sh"
  curl -fsS --max-time 15 "$base/job-$id.sh" -o "$file" || continue
  actual=$(shasum -a 256 "$file" | awk '{print $1}')
  [ "$actual" = "$sha" ] || { report "runner=$$ job=$id status=hash_mismatch"; sleep 2; continue; }
  last=$id
  bash "$file" > "$work/job-$id.log" 2>&1 < /dev/null &
  child=$!; start=$SECONDS
  while kill -0 "$child" 2>/dev/null; do
    report "runner=$$ job=$id pid=$child status=running elapsed=$((SECONDS-start))"
    if [ "$((SECONDS-start))" -ge "$deadline" ]; then
      kill "$child" 2>/dev/null || true
      echo 'RUNNER: job deadline exceeded' >> "$work/job-$id.log"
      break
    fi
    sleep 2
  done
  code=0; wait "$child" || code=$?
  tail -c 16000000 "$work/job-$id.log" | curl -fsS --max-time 30 --data-binary @- "$result-job-$id.log" >/dev/null
  report "runner=$$ job=$id status=finished exit=$code elapsed=$((SECONDS-start)) log_bytes=$(stat -f %z "$work/job-$id.log")"
done
report "runner=$$ status=stopped last_job=$last"

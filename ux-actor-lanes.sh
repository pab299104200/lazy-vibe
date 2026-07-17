#!/usr/bin/env bash

ux_actor_lane_field() {
  local run_dir="$1" job_id="$2" field_number="$3"
  local lane_file="$run_dir/artifacts/ux-fixtures/actor-lanes.tsv"
  [[ -s "$lane_file" ]] || return 0
  awk -F '\t' -v job="$job_id" -v field="$field_number" '
    NR > 1 && $1 == job { print $field; exit }
  ' "$lane_file"
}

ux_job_default_actor() {
  local actor
  actor="$(ux_actor_lane_field "$1" "$2" 2)"
  [[ -z "$actor" || "$actor" =~ ^[A-Za-z0-9_]+$ ]] || return 1
  printf '%s\n' "$actor"
}

ux_job_additional_actors() {
  local actors actor
  actors="$(ux_actor_lane_field "$1" "$2" 3)"
  while IFS= read -r actor; do
    actor="${actor//[[:space:]]/}"
    [[ -n "$actor" ]] || continue
    [[ "$actor" =~ ^[A-Za-z0-9_]+$ ]] || return 1
    printf '%s\n' "$actor"
  done < <(printf '%s\n' "$actors" | tr ',' '\n')
}

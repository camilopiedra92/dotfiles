# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.

# ── Routed Spec Kit ──────────────────────────────────────────────────────────
printf '\n%sRouted Spec Kit%s\n' "$DIM" "$OFF"

# Every schema accepts its sample and refuses the three variants
# checks/sdd/schema-cases.py derives from it: a required field dropped, an
# unknown field added, an enum (or const) field given a value outside it.
sdd_schemas() {
  local tmp name case status=0 schema
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  python3 -I checks/sdd/schema-cases.py "$tmp" || return 1
  for name in routing-table routing-layer route routing phases clarify implement verify review converge; do
    schema=claude/speckit/schemas/$name.schema.json
    [ -f "$schema" ] || {
      echo "$name: no $schema"
      status=1
      continue
    }
    check-jsonschema --schemafile "$schema" "$tmp/$name.valid.json" > /dev/null 2>&1 || {
      echo "$name: refused its valid sample"
      status=1
    }
    for case in missing extra enum; do
      if check-jsonschema --schemafile "$schema" "$tmp/$name.$case.json" > /dev/null 2>&1; then
        echo "$name: accepted the $case variant"
        status=1
      fi
    done
  done
  return "$status"
}
if command -v check-jsonschema > /dev/null 2>&1; then
  check "every routing schema accepts its sample and refuses a missing field, an extra field and a wrong enum" sdd_schemas
else
  skip "every routing schema accepts its sample and refuses a missing field, an extra field and a wrong enum" check-jsonschema
fi

# sdd-step outcome prints the fixed token each branch of the workflow compares,
# from the outcome file of the feature .specify/feature.json names, and fails
# on a file that is missing or that its schema refuses (FR-016).
sdd_outcome() {
  local tmp f status=0
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  f=specs/001-probe
  mkdir -p "$tmp/.specify" "$tmp/$f/.sdd"
  printf '{"feature_directory":"%s"}\n' "$f" > "$tmp/.specify/feature.json"
  local step=$PWD/bin/sdd-step.sh
  put() { # step json-fields
    printf '{"schema":"urn:dotfiles:sdd:%s:1","step":"%s","at":"2026-10-21T14:00:00Z",%s}\n' \
      "$1" "$1" "$2" > "$tmp/$f/.sdd/$1.json"
  }
  expect() { # step want why
    local got
    got=$(cd "$tmp" && "$step" outcome "$1" 2> /dev/null) || got="<exit $?>"
    [ "$got" = "$2" ] || {
      echo "$1, $3: printed '$got', wanted '$2'"
      status=1
    }
  }
  refuses() { # step why
    if (cd "$tmp" && "$step" outcome "$1" > /dev/null 2>&1); then
      echo "$1, $2: exited 0"
      status=1
    fi
  }
  local high='{"severity":"HIGH","text":"x"}' medium='{"severity":"MEDIUM","text":"x"}' low='{"severity":"LOW","text":"x"}'

  refuses clarify "no file"
  put clarify '"questions":3'
  expect clarify yes "three questions"
  put clarify '"questions":0'
  expect clarify no "no question"
  put clarify '"questions":0,"extra":1'
  refuses clarify "a field the schema does not know"
  put verify '"command":"./check.sh","exit":0,"tail":"","check_changes":[],"automation_changes":[]'
  expect verify pass "exit 0"
  put verify '"command":"./check.sh","exit":2,"tail":"","check_changes":[],"automation_changes":[]'
  expect verify fail "exit 2"
  put review "\"findings\":[$low,$high],\"done\":[]"
  expect review blocking "a HIGH finding"
  put review "\"findings\":[$low],\"done\":[\"T001\"]"
  expect review clear "only LOW findings"
  put converge "\"outcome\":\"converged\",\"findings\":[$low]"
  expect converge converged "converged with only LOW findings"
  put converge "\"outcome\":\"converged\",\"findings\":[$medium]"
  expect converge open "converged but a MEDIUM finding"
  put converge '"outcome":"tasks_appended","findings":[]'
  expect converge open "tasks appended"
  put converge '"outcome":"converged"'
  refuses converge "no findings field"
  refuses route "a step with no token to print"
  # A directory that exists and holds a valid file, so only the path's shape
  # can refuse it.
  mkdir -p "$tmp/elsewhere/.sdd"
  put clarify '"questions":1'
  cp "$tmp/$f/.sdd/clarify.json" "$tmp/elsewhere/.sdd/"
  printf '{"feature_directory":"elsewhere"}\n' > "$tmp/.specify/feature.json"
  refuses clarify "a feature directory outside specs/"
  return "$status"
}
if command -v check-jsonschema > /dev/null 2>&1; then
  check "sdd-step outcome prints each step's token and refuses a missing or invalid file" sdd_outcome
else
  skip "sdd-step outcome prints each step's token and refuses a missing or invalid file" check-jsonschema
fi

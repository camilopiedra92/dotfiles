# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own.
#
# No `# covers:` line, so it runs for every change: a pattern goes stale when
# a file it names is renamed or deleted, and that commit is not selected by
# the pattern that just stopped matching. Under `--staged` the sections
# that declare paths would miss exactly the commit that breaks them. Cheap: it
# reads `# covers:` lines and the tracked path list (about a quarter of a second).

printf '\n%sDeclarations%s\n' "$DIM" "$OFF"

this_repo_declarations() {
  local out
  out=$(this_repo_git ls-files | declaration_misses .)
  [ -z "$out" ] || {
    echo "declared patterns matching no tracked file:"
    printf '%s\n' "$out"
    return 1
  }
}
check "every pattern this repository's sections declare matches a tracked file" this_repo_declarations

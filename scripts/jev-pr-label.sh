#!/usr/bin/env bash
# scripts/jev-pr-label.sh — advisory PR labels: deterministic size + Jev Choice risk.
# Not a merge gate. Missing TYPESAFE_API_KEY or API errors warn and exit 0.

set -Eeuo pipefail

TYPESAFE_API_URL="${TYPESAFE_API_URL:-https://api.typesafe.ai/v1/systemone}"
TYPESAFE_MODEL="${TYPESAFE_MODEL:-jev-latest}"
DIFF_EXCERPT_CHARS="${DIFF_EXCERPT_CHARS:-4000}"
FILE_LIST_LIMIT="${FILE_LIST_LIMIT:-40}"

soft_fail() {
  printf 'warning: %s (soft-fail; not a merge gate)\n' "$1" >&2
  exit 0
}

jev_size_from_lines() {
  local total="$1"
  if ((total < 20)); then
    printf 'xs'
  elif ((total < 80)); then
    printf 's'
  elif ((total < 300)); then
    printf 'm'
  else
    printf 'l'
  fi
}

jev_size_from_files() {
  local files="$1"
  if ((files <= 3)); then
    printf 'xs'
  elif ((files <= 8)); then
    printf 's'
  elif ((files <= 20)); then
    printf 'm'
  else
    printf 'l'
  fi
}

jev_size_rank() {
  case "$1" in
    xs) printf '0' ;;
    s) printf '1' ;;
    m) printf '2' ;;
    *) printf '3' ;;
  esac
}

# Size is the larger of the line-count bucket and the file-count bucket.
# Lines = additions + deletions. Jev does not compute size.
jev_size_label() {
  local additions="$1" deletions="$2" files="$3"
  local total line_bucket file_bucket line_rank file_rank
  total=$((additions + deletions))
  line_bucket="$(jev_size_from_lines "${total}")"
  file_bucket="$(jev_size_from_files "${files}")"
  line_rank="$(jev_size_rank "${line_bucket}")"
  file_rank="$(jev_size_rank "${file_bucket}")"
  if ((file_rank > line_rank)); then
    printf 'jev:size-%s\n' "${file_bucket}"
  else
    printf 'jev:size-%s\n' "${line_bucket}"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  jev-pr-label.sh
  jev-pr-label.sh --size ADDITIONS DELETIONS FILES

Advisory GitHub PR labeler. Size comes from gh/git line and file counts.
Risk comes from one TypeSafe System One Choice call (Jev). Never blocks merge.

Environment:
  TYPESAFE_API_KEY   repository secret (required for risk labels)
  GH_TOKEN           GitHub token with pull-requests: write
  PR_NUMBER          pull request number
  GITHUB_REPOSITORY  owner/repo
EOF
}

ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || soft_fail "missing command: $1"
}

ensure_label() {
  local name="$1" color="$2" desc="$3"
  gh label create "${name}" --color "${color}" --description "${desc}" --force >/dev/null
}

strip_jev_labels() {
  local name
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    case "${name}" in
      jev:risk-* | jev:size-*)
        gh pr edit "${PR_NUMBER}" --remove-label "${name}" >/dev/null || true
        ;;
    esac
  done < <(gh pr view "${PR_NUMBER}" --json labels --jq '.labels[].name // empty')
}

apply_labels() {
  local labels=("$@")
  local args=() label
  for label in "${labels[@]}"; do
    [[ -z "${label}" ]] && continue
    args+=(--add-label "${label}")
  done
  ((${#args[@]} > 0)) || return 0
  gh pr edit "${PR_NUMBER}" "${args[@]}" >/dev/null
}

pr_metrics_from_gh() {
  gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" \
    --jq '{title: .title, body: (.body // ""), additions: .additions, deletions: .deletions, changed_files: .changed_files}'
}

pr_file_list_from_gh() {
  set +o pipefail
  gh api --paginate "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/files" \
    --jq '.[] | "\(.filename) +\(.additions)/-\(.deletions) \(.status)"' \
    | head -n "${FILE_LIST_LIMIT}" || true
  set -o pipefail
}

pr_diff_excerpt_from_gh() {
  set +o pipefail
  gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" \
    -H "Accept: application/vnd.github.diff" \
    | head -c "${DIFF_EXCERPT_CHARS}" || true
  set -o pipefail
}

call_jev_choice() {
  local state_json="$1"
  local payload http_code tmp curl_st
  tmp="$(mktemp "${TMPDIR:-/tmp}/jev-choice.XXXXXX")"
  payload="$(
    jq -n \
      --arg model "${TYPESAFE_MODEL}" \
      --argjson state "${state_json}" \
      '{
        model: $model,
        state: $state,
        questions: {
          risk: {
            type: "choice",
            instructions: "Classify merge risk of this pull request using only the provided title, file list, line counts, and diff excerpt. Do not invent cyclomatic complexity or other metrics. Advisory label only; not a merge gate.",
            criteria: {
              low: "Routine, localized, easy to revert: docs, comments, or a small isolated change.",
              medium: "Meaningful behavior change or several files; needs a normal review.",
              high: "Touches secrets, installers, CI permissions, authentication, or is broad and hard to revert."
            }
          }
        }
      }'
  )"
  set +e
  http_code="$(
    curl -sS -o "${tmp}" -w '%{http_code}' \
      --max-time 20 \
      -X POST "${TYPESAFE_API_URL}" \
      -H "Authorization: Bearer ${TYPESAFE_API_KEY}" \
      -H "Content-Type: application/json" \
      -d "${payload}"
  )"
  curl_st=$?
  set -e
  if ((curl_st != 0)); then
    rm -f -- "${tmp}"
    soft_fail "TypeSafe API request failed"
  fi
  if [[ "${http_code}" != 200 ]]; then
    rm -f -- "${tmp}"
    soft_fail "TypeSafe API returned HTTP ${http_code}"
  fi
  jq -r '.answers.risk.choice // .choices.risk.choice // empty' "${tmp}"
  rm -f -- "${tmp}"
}

main() {
  local meta additions deletions files title body size_label risk_choice risk_label
  local files_summary diff_excerpt state_json

  PR_NUMBER="${PR_NUMBER:-${GITHUB_PR_NUMBER:-}}"
  GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
  if [[ -z "${PR_NUMBER}" && -z "${TYPESAFE_API_KEY:-}" ]]; then
    soft_fail "TYPESAFE_API_KEY is not set; skipped Jev risk label"
  fi

  ensure_cmd gh
  ensure_cmd jq
  ensure_cmd curl

  [[ -n "${PR_NUMBER}" ]] || soft_fail "PR_NUMBER is not set"
  [[ -n "${GITHUB_REPOSITORY}" ]] || soft_fail "GITHUB_REPOSITORY is not set"

  meta="$(pr_metrics_from_gh)"
  additions="$(jq -r '.additions' <<<"${meta}")"
  deletions="$(jq -r '.deletions' <<<"${meta}")"
  files="$(jq -r '.changed_files' <<<"${meta}")"
  title="$(jq -r '.title' <<<"${meta}")"
  body="$(jq -r '.body[0:500]' <<<"${meta}")"
  size_label="$(jev_size_label "${additions}" "${deletions}" "${files}")"

  ensure_label "jev:size-xs" "C5DEF5" "Deterministic size: extra small"
  ensure_label "jev:size-s" "74C0FC" "Deterministic size: small"
  ensure_label "jev:size-m" "4C6EF5" "Deterministic size: medium"
  ensure_label "jev:size-l" "364FC7" "Deterministic size: large"
  ensure_label "jev:risk-low" "2B8A3E" "Jev Choice: low merge risk"
  ensure_label "jev:risk-medium" "F59F00" "Jev Choice: medium merge risk"
  ensure_label "jev:risk-high" "C92A2A" "Jev Choice: high merge risk"

  strip_jev_labels
  apply_labels "${size_label}"
  printf 'applied %s (files=%s additions=%s deletions=%s)\n' \
    "${size_label}" "${files}" "${additions}" "${deletions}"

  if [[ -z "${TYPESAFE_API_KEY:-}" ]]; then
    soft_fail "TYPESAFE_API_KEY is not set; skipped Jev risk label"
  fi

  files_summary="$(pr_file_list_from_gh || true)"
  diff_excerpt="$(pr_diff_excerpt_from_gh || true)"
  state_json="$(
    jq -n \
      --arg title "${title}" \
      --arg body "${body}" \
      --argjson additions "${additions}" \
      --argjson deletions "${deletions}" \
      --argjson changed_files "${files}" \
      --arg files_summary "${files_summary}" \
      --arg diff_excerpt "${diff_excerpt}" \
      '{
        title: $title,
        body: $body,
        additions: $additions,
        deletions: $deletions,
        changed_files: $changed_files,
        files_summary: $files_summary,
        diff_excerpt: $diff_excerpt
      }'
  )"

  risk_choice="$(call_jev_choice "${state_json}")"
  case "${risk_choice}" in
    low | medium | high)
      risk_label="jev:risk-${risk_choice}"
      apply_labels "${risk_label}"
      printf 'applied %s (Jev Choice)\n' "${risk_label}"
      ;;
    *)
      soft_fail "Jev Choice returned unexpected value"
      ;;
  esac
}

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == --size ]]; then
  if [[ $# -ne 4 ]]; then
    printf 'usage: jev-pr-label.sh --size ADDITIONS DELETIONS FILES\n' >&2
    exit 2
  fi
  jev_size_label "$2" "$3" "$4"
  exit 0
fi

trap 'soft_fail "unexpected error on line ${LINENO}"' ERR
main "$@"
exit 0

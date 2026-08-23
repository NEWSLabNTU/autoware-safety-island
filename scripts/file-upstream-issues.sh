#!/usr/bin/env bash
# Copyright (c) 2026, Arm Limited.
# SPDX-License-Identifier: Apache-2.0
#
# file-upstream-issues.sh — file the Zephyr defects written up in
# docs/design/upstream-zephyr-issues.md against zephyrproject-rtos/zephyr.
#
# That document is the single source: this script slices it on the `## Issue N`
# headings, so the text that gets filed is the text that was reviewed. Nothing
# is duplicated here.
#
# DEFAULT IS A DRY RUN. It prints the exact `gh issue create` invocations and
# writes the bodies to a staging directory so they can be read before anything
# is published. Filing requires --create AND is interactive: gh prompts before
# each issue.
#
#   scripts/file-upstream-issues.sh              # dry run: show what would be filed
#   scripts/file-upstream-issues.sh --show 3     # print issue 3's body in full
#   scripts/file-upstream-issues.sh --create     # file them (asks per issue)
#   scripts/file-upstream-issues.sh --create 2   # file only issue 2
set -euo pipefail

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
SRC="${ROOT}/docs/design/upstream-zephyr-issues.md"
REPO="zephyrproject-rtos/zephyr"
STAGE="${ROOT}/build/upstream-issues"

MODE=dry
ONLY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --create) MODE=create; shift ;;
    --show)   MODE=show; ONLY="${2:-}"; shift 2 ;;
    -h|--help) sed -n '4,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    [0-9]*)   ONLY="$1"; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

say()  { echo -e "\033[0;32m[issues]\033[0m $*"; }
warn() { echo -e "\033[0;33m[issues]\033[0m $*" >&2; }
die()  { echo -e "\033[0;31m[issues]\033[0m $*" >&2; exit 1; }

[ -f "${SRC}" ] || die "missing ${SRC}"
command -v gh >/dev/null || die "gh not on PATH — install GitHub CLI to file these."

mkdir -p "${STAGE}"

# Split the document into one body file per `## Issue N — <title>` section.
# The shared preamble (environment, versions) is prepended to every body so
# each issue stands alone when read on GitHub.
python3 - "${SRC}" "${STAGE}" <<'PY'
import io, os, re, sys

src, stage = sys.argv[1], sys.argv[2]
text = io.open(src, encoding="utf-8").read()

# Everything between the environment sentence and the first issue heading is
# context every report needs.
env = ""
m = re.search(r"^Environment for both:.*?(?=^---$)", text, re.S | re.M)
if m:
    env = m.group(0).strip()
    # The doc says "for both" because it predates the third issue.
    env = env.replace("Environment for both:", "Environment:")

parts = re.split(r"^## (Issue (\d+) — .*)$", text, flags=re.M)
# parts = [preamble, heading, number, body, heading, number, body, ...]
for i in range(1, len(parts), 3):
    heading, number, body = parts[i], parts[i + 1], parts[i + 2]
    title = heading.split("—", 1)[1].strip()
    body = body.strip()
    # Drop a trailing horizontal rule left by the split.
    body = re.sub(r"\n---\s*$", "", body).strip()

    out = []
    if env:
        out.append(env)
        out.append("")
    out.append(body)
    out.append("")
    out.append("---")
    out.append("")
    out.append("*Found while bringing up CTF tracing and thread statistics on "
               "an Arm FVP BaseR AEMv8-R target. Every claim above was "
               "established by building and running against a control image "
               "rather than by inspection. The code shown is v3.7.0, but the "
               "behaviour is unchanged on `main` as of 2026-08-24.*")

    with io.open(os.path.join(stage, f"issue-{number}.md"), "w",
                 encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")
    with io.open(os.path.join(stage, f"issue-{number}.title"), "w",
                 encoding="utf-8") as fh:
        fh.write(title + "\n")
PY

mapfile -t BODIES < <(find "${STAGE}" -name 'issue-*.md' | sort)
[ "${#BODIES[@]}" -gt 0 ] || die "no issue sections parsed out of ${SRC}"

for body in "${BODIES[@]}"; do
  num="$(basename "${body}" .md | sed 's/issue-//')"
  [ -z "${ONLY}" ] || [ "${ONLY}" = "${num}" ] || continue
  title="$(cat "${STAGE}/issue-${num}.title")"

  case "${MODE}" in
    show)
      echo "===== issue ${num}: ${title} ====="
      cat "${body}"
      ;;
    dry)
      say "issue ${num}: ${title}"
      echo "    body: ${body} ($(wc -l < "${body}") lines)"
      # printf %q so the printed command is safe to copy-paste: these titles
      # contain backticks, which would command-substitute inside double quotes.
      printf '    gh issue create --repo %s \\\n        --title %s \\\n        --body-file %s\n\n' \
             "${REPO}" "$(printf '%q' "${title}")" "${body}"
      ;;
    create)
      say "about to file issue ${num} against ${REPO}:"
      echo "    ${title}"
      # Filing is public and hard to undo, so confirm each one explicitly
      # rather than trusting a single up-front --create.
      read -r -p "    file it? [y/N] " reply
      case "${reply}" in
        y|Y)
          gh issue create --repo "${REPO}" \
             --title "${title}" \
             --body-file "${body}"
          ;;
        *) warn "skipped issue ${num}" ;;
      esac
      ;;
  esac
done

if [ "${MODE}" = "dry" ]; then
  say "dry run only — nothing filed. Bodies staged in ${STAGE}"
  say "read one with: $0 --show <n>     file with: $0 --create"
fi

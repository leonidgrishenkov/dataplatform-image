# CI image for the analytic `dataplatform` GitLab project: everything its Python jobs and
# promote:prod used to install on the fly. dbt:manifest and airflow:lint did `pip install`
# on every run, review:claude installed git, curl and Claude Code, promote:prod ran in
# alpine/git. The gcloud jobs (google/cloud-sdk) and the Liquibase jobs
# (liquibase-clickhouse) keep their own images.
#
# Debian slim, as the jobs ran before: liquibase/lint.sh relies on bash and GNU date. No
# entrypoint, so GitLab CI runs its shell scripts without `entrypoint: [""]`.
ARG PYTHON_VERSION=3.12.16
ARG DEBIAN_CODENAME=trixie
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_CODENAME}

# pipefail for the pipe in the Claude Code RUN below (hadolint DL4006).
SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# Pinned up to the upstream version, with the Debian revision left open: `=1:2.47.*` keeps
# taking security updates, which Debian ships as new revisions and stops serving the old
# ones, while an unpinned package fails hadolint (DL3008) in the release workflow.
# git - review:claude builds the MR's diff, promote:prod pushes; openssh-client -
# promote:prod pushes over SSH with the deploy key; curl - review:claude reads the full MR
# description from the GitLab API. ca-certificates and the rest lint.sh needs (bash, GNU
# coreutils, grep, sed, mawk, findutils) come with the base image.
ARG GIT_VERSION=1:2.47.*
ARG OPENSSH_VERSION=1:10.0p1-*
ARG CURL_VERSION=8.14.1-*

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      "git=${GIT_VERSION}" \
      "openssh-client=${OPENSSH_VERSION}" \
      "curl=${CURL_VERSION}" \
 && rm -rf /var/lib/apt/lists/*

# dbt must be the version Cosmos runs on the Composer workers: DBT_REQUIREMENTS in the
# consumer's airflow/plugins/chillbase/dbt.py. A manifest built by another dbt is what the
# worker then fails to read. ruff as airflow:lint pinned it: a new version can add a rule
# and fail an MR that changed nothing.
ARG DBT_CORE_VERSION=1.11.15
ARG DBT_CLICKHOUSE_VERSION=1.10.3
ARG RUFF_VERSION=0.16.10

RUN pip install --no-cache-dir --root-user-action=ignore \
      "dbt-core==${DBT_CORE_VERSION}" \
      "dbt-clickhouse==${DBT_CLICKHOUSE_VERSION}" \
      "ruff==${RUFF_VERSION}"

# Claude Code, the native binary of an exact version, checked against the sha256 in that
# release's manifest - what install.sh does. install.sh itself is not used: it first
# downloads the latest binary and lets it install the pinned one, into root's home.
ARG CLAUDE_CODE_VERSION=2.1.308
# Set by BuildKit for each platform of a multi-arch build.
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
      amd64) platform=linux-x64 ;; \
      arm64) platform=linux-arm64 ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && release="https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION}" \
 && curl -fsSL -o /tmp/manifest.json "${release}/manifest.json" \
 && curl -fsSL -o /tmp/claude "${release}/${platform}/claude" \
 && python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["platforms"][sys.argv[2]]["checksum"] + "  /tmp/claude")' \
      /tmp/manifest.json "${platform}" | sha256sum -c - \
 && install -m 0755 /tmp/claude /usr/local/bin/claude \
 && rm /tmp/claude /tmp/manifest.json \
 && claude --version

# A job that clears the environment (review:claude runs claude under env -i) passes it
# again itself.
ENV DISABLE_AUTOUPDATER=1

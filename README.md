# dataplatform image

Python with everything the `dataplatform` pipeline's Python jobs and `promote:prod` need
baked in. That project builds the analytic data platform on ClickHouse, dbt, Airflow
(Cloud Composer) and Liquibase, deployed from GitLab CI. This repo produces a versioned
image; the pipeline consumes it by tag and never rebuilds it.

## Publishing

Published to Amazon ECR Public at `public.ecr.aws/a8c0b5z6/dataplatform`.

Releases go through CI: pushing a tag on a commit on `main` runs
[`release.yml`](.github/workflows/release.yml). Its push job waits in the `release`
environment until you approve it (**Review deployments** on the run page), then builds
`linux/amd64` + `linux/arm64` and pushes the image tagged with the git tag, `latest` and
the commit SHA. Tag as `<dbt-core version>-<build>`:

```bash
git tag 1.11.15-1 && git push origin 1.11.15-1
```

Consumers pull it with:

```bash
docker pull public.ecr.aws/a8c0b5z6/dataplatform:1.11.15-1
```

Build a local single-arch copy to test with:

```bash
docker build -t dataplatform:test .
```

Publishing by hand has to be multi-arch: CI runners are almost always amd64, while this is
typically built on an arm64 Mac, and a single-arch push gives an image that fails to run for
most consumers. The default `docker` buildx driver rejects multi-platform builds, so use a
`docker-container` builder. It cannot load the result locally either, so build and push in
one step:

```bash
# ECR Public auth tokens are only issued from us-east-1.
aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws
docker buildx create --name multiarch --driver docker-container --bootstrap   # once
docker buildx build --builder multiarch --platform linux/amd64,linux/arm64 \
  -t public.ecr.aws/a8c0b5z6/dataplatform:1.11.15-1 --push .
docker buildx imagetools inspect public.ecr.aws/a8c0b5z6/dataplatform:1.11.15-1
```

Known consumer: the `analytic/dataplatform` GitLab project, which pins the tag in its
`.gitlab-ci.yml`.

## What is in it and why

The Python jobs ran on stock `python:3.12-slim` and installed their tools on every run;
`promote:prod` ran in `alpine/git`. This image does that once:

| Component | Version | Used by |
|---|---|---|
| `python` (base image) | **3.12.16**, Debian 13 (trixie) | every Python job: `dbt:manifest`, `airflow:validate`, `comments:*`, `review:*` |
| `dbt-core`, `dbt-clickhouse` (pip) | **1.11.15**, **1.10.3** | `dbt:manifest`: `dbt parse` builds the manifest Cosmos reads |
| `ruff` (pip) | 0.16.10 | `airflow:lint` |
| Claude Code | 2.1.308 | `review:claude`: `/usr/local/bin/claude`, the native binary |
| `git` (apt) | 2.47.x | `review:claude` builds the MR's diff, `promote:prod` pushes |
| `openssh-client` (apt) | 10.0p1 | `promote:prod` pushes over SSH with the deploy key |
| `curl` (apt) | 8.14.1 | `review:claude` reads the full MR description from the GitLab API |

`liquibase/lint.sh` needs only what the base image has: bash, GNU coreutils (its time
window uses GNU `date -d`), grep, sed, mawk and findutils. So do `base64` and `mktemp` in
the jobs that decode keys. `ca-certificates` comes with the base image too.

The image is about 665 MB (amd64); Claude Code alone is 292 MB of it.

Not in it, on purpose: the gcloud jobs (`airflow:sync-*`, `airflow:update-pypi-*`,
`airflow:pools-*`) run in `google/cloud-sdk`, and the Liquibase jobs in
[`liquibase-clickhouse`](https://github.com/leonidgrishenkov/liquibase-clickhouse-image),
which carries Java, Liquibase and the ClickHouse jars.

Each version is a build arg, so a version can be tried without editing the Dockerfile:

```bash
docker build --build-arg RUFF_VERSION=0.17.0 -t dataplatform:test .
```

### Pins

- **dbt-core and dbt-clickhouse** must be the versions Cosmos installs on the Composer
  workers: `DBT_REQUIREMENTS` in the consumer's `airflow/plugins/chillbase/dbt.py`. A
  manifest built by another dbt is what the workers then fail to read. Change both places
  together.
- **apt packages** are pinned up to the upstream version, with the Debian revision left
  open (`git=1:2.47.*`). Debian ships security fixes as new revisions and stops serving the
  old ones, so an exact pin stops building, while an unpinned `apt-get install` fails
  hadolint (DL3008) in the release workflow. A new Debian release or point release can
  move a package to another upstream version; if the build then fails to find it, raise
  its build arg to what the base image's Debian ships:

  ```bash
  docker run --rm python:<version>-slim-<codename> \
    sh -c 'apt-get update -qq && apt-cache policy git openssh-client curl'
  ```

- **Claude Code** is not installed with `install.sh`: that script first downloads the
  latest binary and lets it install the pinned one, into root's home. The Dockerfile
  downloads the pinned glibc binary for the build platform (`TARGETARCH`) from
  `downloads.claude.ai` and checks it against the sha256 in that release's
  `manifest.json`, which is what `install.sh` does too.

## Contract for consumers

1. **No entrypoint**, as the upstream Python image: GitLab CI runs its shell scripts as is,
   no `entrypoint: [""]`.
2. **Tools are on `PATH` in `/usr/local/bin`**: `python`, `dbt`, `ruff`, `claude`. A job
   that clears the environment, as `review:claude` does with `env -i`, has to put
   `/usr/local/bin` on its `PATH` and pass `DISABLE_AUTOUPDATER=1` again.
3. **A job that needs another package needs a new image version**, not a `pip install` or
   `apt-get install` in the job.
4. **It runs as root**, like the upstream image.

## Bumping a version

1. Change its build arg in the [`Dockerfile`](Dockerfile): `DBT_CORE_VERSION` and
   `DBT_CLICKHOUSE_VERSION` together with the consumer's `DBT_REQUIREMENTS`;
   `RUFF_VERSION`; `CLAUDE_CODE_VERSION`; `PYTHON_VERSION` or `DEBIAN_CODENAME` for the
   base image, and the apt pins if the build then fails (see above).
2. Merge to `main`, tag and approve the release: `<new dbt-core version>-1` when dbt-core
   changes, otherwise the next build of the same one (`1.11.15-2` after `1.11.15-1`).
3. In the consumer, change the image tag in `.gitlab-ci.yml`.

# Crucible GitHub Actions

Reusable GitHub Actions owned by the Crucible team. Consumers can depend on the actions
in this repository to keep shared automation consistent across applications.

## Available Actions

### Update Helm Chart

`actions/update-helm-chart` synchronizes a Helm chart with a newly published application
release and raises a pull request against `cmu-sei/helm-charts`.

The action:

- extracts a semantic version from the release tag
- infers the release type (`major`/`minor`/`patch`) from the existing `appVersion`
- updates the target chart's `appVersion`
- bumps the chart `version` based on the release type
- optionally bumps parent charts
- pushes a feature branch to the Helm charts repository and opens a PR

#### Inputs

| Name | Required | Description |
| --- | --- | --- |
| `app_name` | ✅ | Friendly name used for commit and PR title, e.g. `TopoMojo API`. |
| `release_tag` | ✅ | Tag from the calling workflow, e.g. `${{ github.event.release.tag_name }}`. |
| `chart_file` | ✅ | Path to the application's `Chart.yaml` within the Helm repo, e.g. `charts/topomojo/charts/topomojo-api/Chart.yaml`. |
| `parent_chart_file` |  | Optional path to a parent `Chart.yaml` that should be bumped. |
| `helm_repo` |  | Helm charts repo (`cmu-sei/helm-charts` by default). |
| `helm_repo_token` |  | Optional token override; if omitted the action uses `HELM_REPO_TOKEN`/`GH_TOKEN` from the environment. |
| `git_user_name` |  | Commit author name (`crucible-bot`). |
| `git_user_email` |  | Commit author email (`crucible-bot@users.noreply.github.com`). |

#### Outputs

- `new_app_version` – parsed version string, e.g. `2.5.2`
- `release_type` – computed release type (`major`/`minor`/`patch`)
- `new_chart_version` – bumped chart version
- `parent_chart_update` – JSON object describing the parent chart bump
- `chart_modified` – `true` when an update was required
- `branch_name` – suggested feature branch for the PR
- `has_changes` – `true` when any files were modified

#### Example Usage

```yaml
name: Publish Release

on:
  release:
    types: [published]

jobs:
  update-helm-chart:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - name: Mint Helm charts token
        id: helm-token
        uses: actions/create-github-app-token@v1
        with:
          app-id: ${{ secrets.HELM_APP_ID }}
          private-key: ${{ secrets.HELM_APP_PRIVATE_KEY }}
          owner: cmu-sei
          repositories: helm-charts

      - name: Update Helm chart
        uses: cmu-sei/crucible-github-actions/actions/update-helm-chart@v1
        env:
          HELM_REPO_TOKEN: ${{ steps.helm-token.outputs.token }}
        with:
          app_name: TopoMojo API
          release_tag: ${{ github.event.release.tag_name }}
          chart_file: charts/topomojo/charts/topomojo-api/Chart.yaml
          parent_chart_file: charts/topomojo/Chart.yaml
```

### Repository Configuration Checklist

1. **Create credentials** for pushing to `cmu-sei/helm-charts`.
   - Preferred: register a GitHub App with `contents:write` and `pull_request:write`, install it on `cmu-sei/helm-charts`, and store the app ID and private key as repository secrets (`HELM_APP_ID`, `HELM_APP_PRIVATE_KEY`). The workflow also supplies the app owner (`cmu-sei`) and repository (`helm-charts`) to the official token action.
   - Alternative: use a fine-grained PAT limited to the Helm charts repo and store as `HELM_CHARTS_TOKEN`; expose it to the workflow as `HELM_REPO_TOKEN` (or pass it via the optional `helm_repo_token` input if preferred).

`with` passes explicit inputs to the composite action (e.g., `app_name` or `chart_file`), whereas `env` sets environment variables that the step can read—handy when shell commands or multiple actions need the same token. In the example above the minted token is made available as `HELM_REPO_TOKEN`; the composite action automatically picks it up without an explicit `with` value.
2. **Add the workflow** (example above) to the application repository.
   - Trigger on `release` with `types: [published]`.
   - Ensure the workflow specifies `permissions.contents: write` and `permissions.pull-requests: write`.
3. **Reference the action** with a tagged version or commit SHA instead of `@main` in production.
4. **Provide chart paths** that match the structure in `cmu-sei/helm-charts`.
   - `chart_file` must point at the child chart’s `Chart.yaml`.
   - `parent_chart_file` should list any umbrella chart `Chart.yaml` files that need a version bump.

When the workflow runs on a release event it will push a feature branch directly to
`cmu-sei/helm-charts` named `update-<slug>-<version>` and open a PR titled
`<App name> to <version>`.

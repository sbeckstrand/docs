# CI/CD for Custom Apps

Custom applications built and hosted in this home lab follow a GitOps-native CI/CD pattern: GitHub Actions builds and publishes the container image, then updates a tag file in the `k8s-apps` repository, and ArgoCD picks up the change and deploys it automatically.

---

## How It Works

### 1. The App Is Defined in k8s-apps

Every application running in the cluster has a Helm chart under `apps/<category>/<name>/` in the [k8s-apps](https://github.com/sbeckstrand/k8s-apps) repository. Apps that use a custom container image keep the image reference in a separate file called `values-image.yaml`:

```yaml
# apps/services/docs/values-image.yaml
image:
  repository: ghcr.io/sbeckstrand/docs
  pullPolicy: IfNotPresent
  tag: "11cff50"
```

Splitting the image tag into its own file keeps it isolated from the rest of the chart configuration, so automated commits only ever touch one file.

### 2. ArgoCD Tracks the App with Auto-Sync

The app is registered in ArgoCD's root values file with `autoSync: true` and the `values-image.yaml` file listed as an additional Helm values source:

```yaml
# argocd/values.yaml
services:
  - name: docs
    namespace: docs
    path: apps/services/docs
    autoSync: true
    valueFiles:
      - values-image.yaml
```

With `autoSync` enabled, ArgoCD polls the repository and applies any changes within a minute or two of a new commit landing on `main`.

### 3. GitHub Actions Builds, Publishes, and Updates the Tag

On every push to `main`, a workflow in the application's own repository:

1. **Builds** the Docker image
2. **Pushes** it to the GitHub Container Registry (`ghcr.io`) tagged with the short commit SHA
3. **Checks out `k8s-apps`** using a Personal Access Token
4. **Updates** `values-image.yaml` with the new tag
5. **Commits and pushes** the change back to `k8s-apps`

ArgoCD detects the new commit in `k8s-apps` and rolls out the updated image automatically.

```
push to main
    │
    ▼
GitHub Actions
    ├── build & push image → ghcr.io/sbeckstrand/<app>:<sha>
    └── update k8s-apps/apps/services/<app>/values-image.yaml
            │
            ▼
        ArgoCD detects change → deploys new image
```

---

## Implementing This for a New App

### Step 1: Create the Helm Chart in k8s-apps

Add a chart under `apps/services/<app-name>/`. At minimum you need a `Chart.yaml`, a `values.yaml`, and a `values-image.yaml`:

```yaml
# values-image.yaml
image:
  repository: ghcr.io/sbeckstrand/<app-name>
  pullPolicy: IfNotPresent
  tag: "latest"
```

The `tag: "latest"` is just a placeholder — the workflow will overwrite it on the first run.

### Step 2: Register the App in ArgoCD

Add an entry to `argocd/values.yaml` under the appropriate category:

```yaml
services:
  - name: <app-name>
    namespace: <app-name>
    path: apps/services/<app-name>
    autoSync: true
    valueFiles:
      - values-image.yaml
```

Commit and push — ArgoCD's root app will pick up the new entry and create the Application on the next sync.

### Step 3: Add the GitHub Actions Workflow

In the application's own repository, create `.github/workflows/docker-build.yaml`:

```yaml
name: Build and Push Docker Image

on:
  push:
    branches:
      - main
  workflow_dispatch:

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - name: Check out the repo
        uses: actions/checkout@v4

      - name: Set short SHA
        run: echo "SHORT_SHA=$(echo $GITHUB_SHA | cut -c1-7)" >> $GITHUB_ENV

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push Docker image
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ghcr.io/${{ github.repository_owner }}/<app-name>:${{ env.SHORT_SHA }}

  update-image-tag:
    runs-on: ubuntu-latest
    needs: build-and-push
    steps:
      - name: Set short SHA
        run: echo "SHORT_SHA=$(echo $GITHUB_SHA | cut -c1-7)" >> $GITHUB_ENV

      - name: Checkout k8s-apps Repository
        uses: actions/checkout@v4
        with:
          repository: sbeckstrand/k8s-apps
          path: k8s-apps
          ref: main
          token: ${{ secrets.K8S_APPS_PAT }}

      - name: Update Image Tag
        run: |
          sed -i "s/tag: \".*\"/tag: \"${{ env.SHORT_SHA }}\"/" \
            k8s-apps/apps/services/<app-name>/values-image.yaml

      - name: Commit and Push Changes
        run: |
          cd k8s-apps
          git config --global user.email "github-actions[bot]@users.noreply.github.com"
          git config --global user.name "github-actions[bot]"
          git add apps/services/<app-name>/values-image.yaml
          git commit -m "Update <app-name> image tag to ${{ env.SHORT_SHA }}"
          git push
```

Replace `<app-name>` with the actual application name.

### Step 4: Configure the GitHub Actions Secret

The workflow needs a Personal Access Token (PAT) with write access to `k8s-apps` to commit the tag update.

1. Retrieve the `K8S_APPS_PAT` token from **1Password**
2. In the application's GitHub repository, go to **Settings → Secrets and variables → Actions**
3. Create a new repository secret named `K8S_APPS_PAT` and paste the token value

The `GITHUB_TOKEN` secret (used to push to the container registry) is provided automatically by GitHub Actions and requires no setup.

!!! note
    If the PAT has expired, generate a new one with **Contents: Read and Write** access scoped to the `sbeckstrand/k8s-apps` repository, store the new value in 1Password, and update the `K8S_APPS_PAT` secret in every repo that uses it.

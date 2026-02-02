---
name: Setup Branch Protection
description: Configure GitHub branch protection rules for a DataSurface model repository. Guides through the two-step process required because the status check must run once before it can be made mandatory.
---

# Setup Branch Protection for DataSurface Model Repository

This skill guides you through setting up branch protection rules on GitHub for a DataSurface model repository. This ensures all changes go through pull requests and pass the DataSurface PR Validator.

## IMPORTANT: Two-Step Process Required

GitHub has a limitation: you cannot add a status check as required until it has run at least once. This means we need a two-step process:

1. **First**: Create an initial PR to trigger the DataSurface PR Validator action
2. **Then**: Configure the branch ruleset with the required status check

## Prerequisites

Before starting, verify:

- [ ] The model repository exists on GitHub with the workflow file (`.github/workflows/pull-request.yml`)
- [ ] You have admin access to the repository
- [ ] The `gh` CLI is installed and authenticated

Ask the user for:

```text
REPO_OWNER     # GitHub org or username (e.g., billynewport)
REPO_NAME      # Repository name (e.g., demo1_actual)
```

---

## Step 0: Verify Required Secrets Exist

The PR workflow requires two secrets to pull the DataSurface Docker image from GitLab. Check they are configured:

```bash
# List repository secrets
gh secret list --repo ${REPO_OWNER}/${REPO_NAME}
```

**Required secrets:**

- `GITLAB_USERNAME` - GitLab deploy token username
- `GITLAB_ACCESS_TOKEN` - GitLab deploy token

If either secret is missing, they must be added before proceeding:

```bash
# Add secrets (will prompt for values)
gh secret set GITLAB_USERNAME --repo ${REPO_OWNER}/${REPO_NAME}
gh secret set GITLAB_ACCESS_TOKEN --repo ${REPO_OWNER}/${REPO_NAME}
```

Or direct the user to add them via the GitHub UI:

```text
https://github.com/${REPO_OWNER}/${REPO_NAME}/settings/secrets/actions
```

**Checkpoint:** Both `GITLAB_USERNAME` and `GITLAB_ACCESS_TOKEN` appear in the secrets list

---

## Step 1: Verify Workflow File Exists

Check that the PR workflow is in place:

```bash
# The workflow file should exist at .github/workflows/pull-request.yml
cat .github/workflows/pull-request.yml
```

If missing, the file needs to be added from the template repository.

**Checkpoint:** Workflow file exists and contains `datasurface-pr-validator` job

---

## Step 2: Create Initial PR to Trigger the Action

We need to create a trivial PR so the GitHub Action runs at least once. This registers the status check with GitHub.

### 2a. Create a new branch

```bash
git checkout main
git pull origin main
git checkout -b trigger-action-setup
```

### 2b. Make a trivial change

Create or modify a file that won't affect functionality:

```bash
# Option 1: Add/update a .github/CODEOWNERS file
echo "# DataSurface model repository" > .github/CODEOWNERS
echo "* @${REPO_OWNER}" >> .github/CODEOWNERS

# Option 2: Or just touch a README
echo "" >> README.md
```

### 2c. Commit and push

```bash
git add .
git commit -m "Initial setup for branch protection"
git push -u origin trigger-action-setup
```

### 2d. Create the Pull Request

```bash
gh pr create --title "Setup: Trigger initial PR validator run" \
  --body "This PR triggers the DataSurface PR Validator action so it can be added as a required status check for branch protection."
```

**Checkpoint:**

- PR is created
- Wait for the "DataSurface PR Validator" check to appear and complete (may take 1-2 minutes)
- Verify the check ran by viewing the PR on GitHub - look for the green checkmark or red X

---

## Step 3: Merge the Initial PR

Once the DataSurface PR Validator check completes (pass or fail - we just need it to run):

```bash
# If the check passed, merge the PR
gh pr merge --squash --delete-branch

# If the check failed but we just need to register it, we can close without merging
# gh pr close --delete-branch
```

Return to main branch:

```bash
git checkout main
git pull origin main
```

**Checkpoint:** PR is merged or closed, and you're back on main

---

## Step 4: Configure Branch Ruleset on GitHub

Now that the status check has run once, we can add it as a required check.

Choose **Option A** (CLI) for automated setup or **Option B** (UI) for manual configuration.

### Option A: Create Ruleset via CLI (Recommended)

Create the ruleset using the GitHub API:

```bash
gh api repos/${REPO_OWNER}/${REPO_NAME}/rulesets \
  --method POST \
  -f name="Datasurface" \
  -f target="branch" \
  -f enforcement="active" \
  --input - << 'EOF'
{
  "name": "Datasurface",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["~DEFAULT_BRANCH"],
      "exclude": []
    }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "required_reviewers": [],
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["merge", "squash", "rebase"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": true,
        "required_status_checks": [
          {
            "context": "DataSurface PR Validator"
          }
        ]
      }
    }
  ],
  "bypass_actors": []
}
EOF
```

Verify the ruleset was created:

```bash
gh api repos/${REPO_OWNER}/${REPO_NAME}/rulesets --jq '.[].name'
```

**Checkpoint:** "Datasurface" appears in the ruleset list

---

### Option B: Create Ruleset via GitHub UI

#### 4a. Navigate to Repository Settings

Open in browser:

```text
https://github.com/${REPO_OWNER}/${REPO_NAME}/settings/rules
```

Or use the GitHub CLI:

```bash
open "https://github.com/${REPO_OWNER}/${REPO_NAME}/settings/rules"
```

#### 4b. Create New Ruleset

1. Click **"New ruleset"** → **"New branch ruleset"**
2. Configure the following:

**Ruleset name:** `Datasurface`

**Enforcement status:** `Active`

**Target branches:**

- Click "Add target" → "Include default branch"

**Branch rules - Enable these:**

| Rule | Setting |
| ------ | --------- |
| **Restrict deletions** | Enabled |
| **Require a pull request before merging** | Enabled |
| - Required approvals | 0 (or your preference) |
| - Dismiss stale reviews | Enabled |
| **Require status checks to pass** | Enabled |
| - Require branches to be up to date | Enabled |
| - Status checks: | **DataSurface PR Validator** |
| **Block force pushes** | Enabled |

#### 4c. Add the Status Check

In the "Require status checks to pass" section:

1. Click "Add checks"
2. Search for "DataSurface PR Validator"
3. Select it from the dropdown (it should now appear because the action ran)

#### 4d. Save the Ruleset

Click **"Create"** to save the ruleset.

**Checkpoint:** Ruleset is created and active

---

## Step 5: Verify Protection is Working

Test that the protection is in place:

```bash
# Try to push directly to main (should fail)
git checkout main
echo "test" >> test-protection.txt
git add test-protection.txt
git commit -m "Test direct push"
git push origin main
# This should be rejected!

# Clean up the test commit
git reset --hard HEAD~1
```

**Checkpoint:** Direct push to main is rejected with a message about branch protection rules

---

## Troubleshooting

### Status check not appearing in dropdown

- Verify the PR from Step 2 triggered the GitHub Action
- Check the Actions tab: `https://github.com/${REPO_OWNER}/${REPO_NAME}/actions`
- The workflow must have run at least once (even if it failed)

### Action failed on initial PR

That's okay! The purpose of the initial PR is just to register the status check with GitHub. You can still proceed with configuring the ruleset. The check will work correctly on future PRs once the repository secrets are properly configured.

### Missing GitLab secrets

If the action fails due to authentication, go back to **Step 0** and ensure both secrets are configured:

- `GITLAB_USERNAME` - GitLab deploy token username
- `GITLAB_ACCESS_TOKEN` - GitLab deploy token

These credentials must have access to pull DataSurface images from `registry.gitlab.com`.

### API error when creating ruleset

If the `gh api` command fails with "Resource not accessible by integration":

- Ensure you have admin access to the repository
- Try authenticating with: `gh auth login`

If it fails with "Validation failed" mentioning the status check:

- The status check hasn't run yet - complete Steps 1-3 first
- Verify the action ran by checking: `https://github.com/${REPO_OWNER}/${REPO_NAME}/actions`

### Deleting a ruleset to recreate it

```bash
# List rulesets to get the ID
gh api repos/${REPO_OWNER}/${REPO_NAME}/rulesets --jq '.[] | "\(.id) \(.name)"'

# Delete by ID
gh api repos/${REPO_OWNER}/${REPO_NAME}/rulesets/{ruleset_id} --method DELETE
```

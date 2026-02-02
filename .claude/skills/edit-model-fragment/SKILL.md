---
name: Edit DataSurface model fragment
description: Check out latest model from main, edit files, then commit and push to owningRepo branch to create a PR
---

# Edit Model Fragment Workflow

This skill helps you edit a DataSurface model by:

1. Pulling the latest model from the main branch
2. Letting you edit the files
3. Switching to the correct owningRepo branch
4. Committing and pushing (which creates a PR)

## Quick Reference

### Key Concepts

- **Model**: Python code in a Git repo describing your data infrastructure
- **GCO (GitControlledObject)**: A model component with its own owner (Ecosystem, RTE, PSP, GZ, Team)
- **owningRepo**: The repo/branch that has permission to modify a GCO
- **liveRepo**: The main branch where approved changes are merged

### The Workflow

```text
1. Pull latest from main     →  Get current model state
2. Edit your files           →  Make changes to your GCO
3. Switch to owningRepo branch  →  The branch authorized for your changes
4. Commit and push           →  Creates PR to main automatically
```

## Step-by-Step Instructions

### Step 1: Start Fresh from Main

```bash
git checkout main
git pull origin main
```

### Step 2: Delete Old owningRepo Branch (Local and Remote)

This avoids "branch is behind" errors by starting fresh each time.

```bash
# Delete local branch if it exists
git branch -D <owningRepo-branch>  # e.g., git branch -D edit

# Delete remote branch if it exists
git push origin --delete <owningRepo-branch>  # e.g., git push origin --delete edit
```

### Step 3: Identify Which Files to Edit

Ask the user which GCO they want to modify:

- **Team changes** → Edit the team's Python file (e.g., `sales_team.py`)
- **GovernanceZone changes** → Edit the GZ file (e.g., `usa_gz.py`)
- **RTE/PSP changes** → Edit the RTE or PSP file

### Step 4: Let User Make Edits

Help the user edit their model files. Common changes include:

- Adding/modifying Datasets in a Datastore
- Adding/modifying Workspaces
- Updating schema definitions
- Adding new Datastores

### Step 5: Create Fresh owningRepo Branch, Commit, and Push

```bash
# Create fresh branch from main
git checkout -b <owningRepo-branch>  # e.g., git checkout -b edit

# Stage and commit
git add <modified-files>
git commit -m "Description of changes"

# Push (creates the branch on remote)
git push -u origin <owningRepo-branch>
```

This push creates a PR to main, where DataSurface validates:

- Model consistency
- Authorization (PR comes from correct owningRepo)
- Backward compatibility

## Authorization Rules

Only the owningRepo can modify its GCO:

- Team changes must come from Team's owningRepo
- GZ changes must come from GZ's owningRepo
- Declarations (adding new GCOs) must come from the **parent's** owningRepo

## Tips

- Always pull latest from main before editing
- One file per GCO minimizes merge conflicts
- Test locally before pushing: `python -c "from eco import createEcosystem; createEcosystem()"`

# nest-release-demo

A small NestJS API used to practise versioned releases and rollback on an Ubuntu server, without Docker.

| Endpoint | What it returns |
|---|---|
| GET / | A page that says "This is version X" |
| GET /health | { status: ok, version: X } |
| GET /api/version | Name, version, host name, start time |
| GET /api/products | Static product list |
| GET /api/users | Static user list |

Release flow: change the version in package.json, commit, tag it (for example v1.1.0) and push the tag.
GitHub Actions builds the app, copies it to the server, keeps every old version in /opt/nestapp/releases,
switches the `current` symlink and checks /health. To go back, run the Rollback workflow with an older version.

Folders: `src` (the app), `infra` (Terraform), `.github/workflows` (CI/CD).

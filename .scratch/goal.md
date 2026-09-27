# Goal

Build a convenient way to isolate typical Phoenix apps (esbuild pipeline + Postgres database) in a [microsandbox] microVM sandbox.

**Requirements:**

1. Use an OCI container image as the root filesystem.
2. Base the image on Alpine Linux and install only the necessary dependencies.
3. Depend on the project-specified [mise-en-place] toolchain rather than system dependencies.
4. Isolate the database in the VM (do not share the host DB).
5. Ensure Git worktrees get their own VMs so dependencies can drift and data is not shared.
6. Cache dependencies between VM runs when it makes sense.

Start with a detailed plan, but _do not build anything_ until I give the go ahead.

[microsandbox]: https://docs.microsandbox.dev/getting-started/introduction
[mise-en-place]: https://mise.jdx.dev/

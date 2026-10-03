# Persistent shell history

Compose owns the history directory mount and sets HISTFILE to its .zsh_history file.
The default Docker engine volume is `dev-benches_pybenchhistory`, matching the verified Compose installation used for this cleanup.

Before recreating a container on another installation, inspect its existing mounts:

```sh
docker inspect py-bench --format '{{range .Mounts}}{{println .Name .Destination}}{{end}}'
docker volume ls
```

Older Dev Container configurations could use the literal volume `pybench-zshhistory` instead.
If that is where your history lives, set `WORKBENCH_HISTORY_VOLUME=pybench-zshhistory`
in the Compose environment (or the .env file beside docker-compose.yml) before recreation.
Use the exact engine name shown by your existing mount, including any project prefix.
The override selects that volume directly; it does not copy, merge, or delete history.
If multiple candidate volumes contain history, preserve them and choose the intended one explicitly.

A named volume mounted at the history directory should contain a .zsh_history file at
its root. If an older installation has a different layout, back it up and migrate that
file before switching. Do not delete the old volume or run Compose with `down -v`.

The startup command repairs ownership for the image's non-root account. Recreating a
container is a separate activation step; these source changes do not restart a live bench.


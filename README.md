# symbol_action

## Development

As tag `v0.1` is automatically moved to latest commit by action `tag`, it is not possible to make `git push` without `-f` option.

Git hooks can help to avoid such inconvenience. Just make the following `pre-push` hook:

    echo '#!/bin/sh' > .git/hooks/pre-push
    echo 'git tag -d "v0.1"' >> .git/hooks/pre-push
    chmod a+x .git/hooks/pre-push

This hook will remove tag `v0.1` in local repository before push and this allows to push without `-f` option.

The latest tag state can be retrieved (in a several seconds after push) by `git fetch`.

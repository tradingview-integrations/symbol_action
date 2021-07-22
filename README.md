# symbol_action

## Development

As tag `v0.1` is automatically moved to latest commit by action, it is not possible to make `git push` without `-f` option.
To avoid such inconvenience by git hooks. Just make the following `pre-push` hook:

    echo '#!/bin/sh' > .git/hooks/pre-push
    echo 'git tag -d $(git tag)' >> .git/hooks/pre-push
    chmod a+x .git/hooks/pre-push

This hook will remove tag before push and it will allow to push without `-f` option.
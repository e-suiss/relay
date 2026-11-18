# Command line

The `relay` command line tool talks to the Relay API with an Access API client. It sends test events, previews templates, keeps workflows, templates and routes in git, follows the activity log, forwards webhooks to your machine and drives kill switches. Every command has JSON output for scripts and agents, and stable exit codes.

## Install and configure

Build it from a checkout with `mix escript.build`. The executable is written to `_build/escript/relay` and needs only Erlang/OTP to run.

```sh
export RELAY_API_URL=https://relay.example.com
export RELAY_ACCESS_ISSUER=https://access.example.com
export RELAY_ENVIRONMENT=test
export RELAY_CLIENT_ID=cli_...
export RELAY_CLIENT_SECRET_FILE=~/.config/relay/test.secret
```

The same settings can live in profiles in `~/.config/relay/config.json`, chosen with `--profile` or `RELAY_PROFILE`. An API client belongs to one environment, `test` or `live`; the tool always knows which one it is talking to.

## Commands

| Command                                                   | What it does                                                                                       |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `trigger <workflow>`                                      | Send an event to a workflow (`--to`, `--recipient`, `--data`, `--data-file`, `--dedup-key`)        |
| `preview <workflow>`                                      | Dry-run an event in the test environment; `--template` renders a template, `--steps` the workflow  |
| `pull [key...]`                                           | Write route, template and workflow definitions to files under `relay/`                             |
| `push [file...]`                                          | Write definition files back as drafts; `--publish` publishes them                                  |
| `promote <key...>` / `--all`                              | Publish definitions of `test` in `live`                                                            |
| `logs`                                                    | Show recent notifications; `--follow` keeps watching, `--why --subscriber <id>` explains decisions |
| `listen --forward-to <url>`                               | Forward your environment's webhook events to a local URL, signed like production                   |
| `kill-switch list`, `get`, `engage`, `replace`, `release` | Inspect and drive kill switches                                                                    |
| `help`                                                    | Show every option                                                                                  |

```sh
relay trigger welcome --to user-4821 --data '{"first_name": "Ayşe"}'
relay preview welcome --to user-4821 --data-file data.json
relay logs --follow
relay logs --why --subscriber user-4821
relay listen --forward-to http://localhost:3000/relay
relay pull --format yaml
relay push --publish
relay promote welcome --yes
relay kill-switch engage --scope workflow --ref welcome --reason "bad copy" --ttl PT1H
```

`pull` writes one JSON or YAML file per definition with sorted keys, so a git diff shows only what changed. `push` checks every file against the definition schema before it sends anything and reports each error with its JSON Pointer. A workflow that files manage becomes code-managed; a workflow managed in the console is left alone unless you pass `--manage-as-code`.

## Changes to `live`

A command that changes the `live` environment asks for confirmation, or takes `--yes`. Without a terminal to ask and without `--yes`, it stops with exit code `8`.

## JSON output

With `--json`, a command prints one JSON object on standard output and always includes `exit_code`:

```json
{ "exit_code": 0, "command": "trigger", "result": { "object": "event", "status": "accepted" } }
```

A failure carries the problem instead of the result:

```json
{ "exit_code": 5, "command": "trigger", "error": { "status": 422, "code": "validation_failed" } }
```

Polling commands (`logs --follow`, `listen`) first print one object per line for each item, `{"type": ..., "data": ...}`, and end with the result object.

## Exit codes

The table is stable: codes are only ever added.

| Code | Meaning                                                       |
| ---- | ------------------------------------------------------------- |
| `0`  | Success                                                       |
| `1`  | Unexpected error                                              |
| `2`  | Usage error: unknown command or option, missing configuration |
| `3`  | Authentication or authorization (401, 403)                    |
| `4`  | Not found (404)                                               |
| `5`  | Validation or conflict (400, 409, 412, 413, 415, 422, 428)    |
| `6`  | Rate limit or quota (429)                                     |
| `7`  | Server or connection (5xx, network error, timeout)            |
| `8`  | A change to `live` was not confirmed                          |

# Skills package

The skills package teaches an AI agent how to use Relay well: which tool to call, how to make retries safe, how to wait for people without polling, and how to treat what it reads. Each skill is a plain Markdown file with a `name` and a `description` in its front matter, the format agent tools load as skills. They describe the [MCP tools](./mcp) and work the same over the HTTP API.

The files live in [`site/skills/`](https://github.com/e-suiss/relay/tree/main/site/skills) of the repository. Copy the folders into your agent's skills directory, or paste a file into its system prompt. CI checks that every tool a skill names exists in Relay's MCP catalogue.

| Skill                     | Use it when the agent                                        |
| ------------------------- | ------------------------------------------------------------ |
| `relay-notify`            | notifies, alerts or reminds someone, or publishes to a topic |
| `relay-wait-for-response` | needs an answer, a review or an event before it can continue |
| `relay-mailbox`           | receives anything from Relay or is woken up by it            |
| `relay-agent-safety`      | reads any content that came through Relay                    |

## relay-notify

<<< @/skills/relay-notify/SKILL.md{md}

## relay-wait-for-response

<<< @/skills/relay-wait-for-response/SKILL.md{md}

## relay-mailbox

<<< @/skills/relay-mailbox/SKILL.md{md}

## relay-agent-safety

<<< @/skills/relay-agent-safety/SKILL.md{md}

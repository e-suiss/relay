# Status page

A static status page for Relay's customers: plain HTML and CSS, no JavaScript, no build tools beyond `jq`. Relay never announces its own incidents through Relay, so this page is hosted apart from every Relay region and from the infrastructure Relay runs on.

## Layout

| Path | What it is |
|---|---|
| `site.json` | Page name, description, contact line and the components with their regions |
| `incidents/*.json` | One file per incident; open and resolved incidents live side by side |
| `examples/` | A sample incident, used by CI to check the page renders |
| `render.jq`, `style.css` | The template |
| `build.sh` | Builds `dist/index.html`, `dist/status.json` and `dist/style.css` |

## Writing an incident

Create `incidents/<date>-<slug>.json`:

```json
{
  "id": "2026-11-18-push-delay",
  "title": "Delayed push notifications on iOS",
  "status": "investigating",
  "impact": "degraded",
  "components": ["push"],
  "regions": ["eu"],
  "started_at": "2026-11-18T09:12:00Z",
  "resolved_at": null,
  "updates": [
    { "at": "2026-11-18T09:20:00Z", "status": "investigating", "body": "What customers see, by message class." }
  ]
}
```

- `status`: `investigating`, `identified`, `monitoring` or `resolved`.
- `impact`: `degraded`, `partial_outage` or `major_outage`; a component shows the worst impact of its open incidents.
- Times are UTC. Add an update for every change and at least at the rhythm the incident's severity requires; set `status` to `resolved` and fill `resolved_at` at the end.
- Say what happened, not what might have happened, and state plainly what cannot be undone.

## Building and publishing

```sh
ops/status-page/build.sh            # writes ops/status-page/dist
ops/status-page/build.sh /tmp/site  # or any output directory
```

The script only builds. Publishing is the installation operator's own step, with their own account at a static host that shares nothing with Relay's hosting, for example an object storage bucket with a CDN in another provider. Keep the credentials for that account and a checkout of this directory on the laptops of everyone in the on-call rotation, so the page can be updated when Relay, its region and its CI are all down. Self-hosted installations follow the same rule.

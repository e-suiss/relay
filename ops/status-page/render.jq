def esc: tostring | @html;

def caption:
  {
    "operational": "Operational",
    "degraded": "Degraded performance",
    "partial_outage": "Partial outage",
    "major_outage": "Major outage",
    "investigating": "Investigating",
    "identified": "Identified",
    "monitoring": "Monitoring",
    "resolved": "Resolved"
  }[.] // .;

def rank: {"operational": 0, "degraded": 1, "partial_outage": 2, "major_outage": 3}[.];

def valid:
  if (.id | type) == "string"
    and (.title | type) == "string"
    and ((.status as $s | ["investigating", "identified", "monitoring", "resolved"] | index($s)) != null)
    and ((.impact as $i | ["degraded", "partial_outage", "major_outage"] | index($i)) != null)
    and (.components | type) == "array"
    and (.regions | type) == "array"
    and (.started_at | type) == "string"
    and (.updates | type) == "array"
    and (.updates | length) > 0
    and all(.updates[]; (.at | type) == "string" and (.status | type) == "string" and (.body | type) == "string")
  then .
  else error("invalid incident: \(.id // "without id")")
  end;

def worst: (map(.impact) | max_by(rank)) // "operational";

def updates:
  .updates
  | sort_by(.at)
  | reverse
  | map("<li><time datetime=\"\(.at | esc)\">\(.at | esc)</time> <strong>\(.status | caption | esc)</strong>: \(.body | esc)</li>")
  | join("\n");

def incident:
  "<article id=\"\(.id | esc)\">\n<h3>\(.title | esc)</h3>\n<p class=\"muted\">\(.status | caption | esc) · \(.impact | caption | esc) · \(.components | join(", ") | esc) · \(.regions | join(", ") | esc) · since <time datetime=\"\(.started_at | esc)\">\(.started_at | esc)</time>\(if .resolved_at then " · resolved <time datetime=\"\(.resolved_at | esc)\">\(.resolved_at | esc)</time>" else "" end)</p>\n<ul>\n\(updates)\n</ul>\n</article>";

. as $site
| ($incidents[0] | map(valid) | sort_by(.started_at) | reverse) as $all
| ($all | map(select(.status != "resolved"))) as $open
| ($all | map(select(.status == "resolved")) | .[0:20]) as $past
| ($site.components | map(.regions[]) | unique) as $regions
| def state($component; $region):
    $open | map(select((.components | index($component)) != null and (.regions | index($region)) != null)) | worst;
  ($open | worst) as $overall
| if $mode == "json" then
    {
      generated: $generated,
      overall: $overall,
      open: ($open | map(.id)),
      components: [
        $site.components[] as $c
        | $c.regions[] as $r
        | {id: $c.id, region: $r, state: state($c.id; $r)}
      ]
    }
  else
    [
      "<!doctype html>",
      "<html lang=\"en\">",
      "<head>",
      "<meta charset=\"utf-8\">",
      "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
      "<title>\($site.name | esc)</title>",
      "<link rel=\"stylesheet\" href=\"style.css\">",
      "</head>",
      "<body>",
      "<header><h1>\($site.name | esc)</h1><p>\($site.description | esc)</p></header>",
      "<main>",
      "<p class=\"banner \($overall)\" role=\"status\">\(if $overall == "operational" then "All systems operational" else ($overall | caption | esc) end)</p>",
      "<h2>Components</h2>",
      "<table>",
      "<tr><th scope=\"col\">Component</th>\($regions | map("<th scope=\"col\">\(. | ascii_upcase | esc)</th>") | join(""))</tr>",
      ($site.components[] as $c
        | "<tr><th scope=\"row\">\($c.name | esc)</th>\($regions | map(. as $r | if ($c.regions | index($r)) != null then state($c.id; $r) as $s | "<td class=\"state \($s)\">\($s | caption | esc)</td>" else "<td>-</td>" end) | join(""))</tr>"),
      "</table>",
      "<h2>Current incidents</h2>",
      (if ($open | length) == 0 then "<p>No current incidents.</p>" else ($open[] | incident) end),
      "<h2>Past incidents</h2>",
      (if ($past | length) == 0 then "<p>No past incidents.</p>" else ($past[] | incident) end),
      "</main>",
      "<footer><p class=\"muted\">\($site.contact | esc)</p><p class=\"muted\">Generated <time datetime=\"\($generated | esc)\">\($generated | esc)</time>.</p></footer>",
      "</body>",
      "</html>"
    ]
    | join("\n")
  end

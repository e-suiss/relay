import { getAccessToken, keyPair, relayUrl } from "./credentials.ts";
// #region send
import { RelayServerClient, dpopAuthenticator } from "@esuiss/relay";

const relay = new RelayServerClient({
  baseUrl: relayUrl,
  authenticate: dpopAuthenticator({ accessToken: getAccessToken, keyPair }),
});

const accepted = await relay.call("createEvent", {
  body: {
    workflow: "welcome",
    to: [{ id: "user-4821", email: "ayse@example.com" }],
    data: { first_name: "Ayşe" },
  },
});
console.log(accepted);
// #endregion send

if (!("status" in accepted) || accepted.status !== "accepted") {
  throw new Error("the event was not accepted");
}

// #region decisions
for await (const decision of relay.paginate("listSubscriberDecisions", {
  path: { subscriber_id: "user-4821" },
  query: { limit: 10 },
})) {
  for (const delivery of decision.deliveries) {
    console.log(decision.notification_id, delivery.channel, delivery.status, delivery.rule_id);
  }
}
// #endregion decisions

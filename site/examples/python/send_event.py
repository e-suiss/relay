from credentials import auth, relay_url

# #region send
from esuiss_relay import Relay

relay = Relay(relay_url, auth)

accepted = relay.create_event(
    {
        "workflow": "welcome",
        "to": [{"id": "user-4821", "email": "ayse@example.com"}],
        "data": {"first_name": "Ayşe"},
    }
)
print(accepted["id"])
# #endregion send

assert accepted["status"] == "accepted"

# #region decisions
for decision in relay.list_subscriber_decisions("user-4821", limit=10):
    for delivery in decision["deliveries"]:
        print(decision["notification_id"], delivery["channel"], delivery["status"])
# #endregion decisions

# #region errors
from esuiss_relay import ValidationError

try:
    relay.create_event({"workflow": "welcome", "to": []})
except ValidationError as error:
    print(error.code, error.problem.get("errors"))
# #endregion errors

-- T-95
CREATE TABLE relay_outbox (
  id bigint PRIMARY KEY,
  payload jsonb NOT NULL,
  relay_claimed_until timestamp with time zone,
  relayed_at timestamp with time zone,
  relay_outcome text
);

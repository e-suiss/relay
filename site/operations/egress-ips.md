# Static egress IPs

Some providers, such as SMS operators in Türkiye, accept API calls only from IP addresses they have allowed. Many companies also allow only known addresses to reach their webhook receivers. For both, every region sends its outbound traffic from a fixed set of IP addresses, and those addresses never leave the region.

## Where to find them

An installation publishes its egress addresses in its discovery document:

```text
GET https://tr.relay.suiss.app/.well-known/relay-configuration
```

The document is public, needs no credentials and may be cached for five minutes. Read the egress addresses from it when you configure an allow list, and read it again when you are told the list changes; do not copy addresses from screenshots or old tickets.

## Setting them when you self-host

On a self-hosted installation the addresses come from the `RELAY_EGRESS_IPS` setting, a comma-separated list of the IPv4 and IPv6 addresses your outbound traffic leaves from. Relay does not discover them: set it to the addresses of your NAT gateway or egress proxy, so the discovery document tells providers and webhook receivers the truth. A provider that requires an allow list cannot be used until the installation has static outbound addresses.

## Webhook deliveries

Webhook deliveries leave from these same addresses. They are sent by workers that run in a network segment with no access to internal services, optionally through an egress proxy, and redirects are never followed. See [Webhooks](/guide/webhooks) for the receiving side.

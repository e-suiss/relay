# Front layer and TLS

Relay does not terminate TLS itself. It runs behind a reverse proxy or load balancer, and trusts forwarded headers only from the addresses listed in `RELAY_TRUSTED_PROXIES`. In front of that proxy you may add a CDN, a web application firewall or DDoS protection. This page explains where such a front layer may sit and where TLS is allowed to end.

## A front layer is optional

Relay works without any CDN or WAF. Add one when you need its protection, and choose it by the data residency rules of the region it serves. A front layer that terminates TLS sees every request in clear text, including personal data in request bodies, so it is a data processor in its own right and must meet the same residency rules as the region.

## Regulated tenants in Türkiye

For tenants in Türkiye that are bound by domestic data rules, such as banks and payment institutions, TLS must never be terminated outside Türkiye. Two set-ups satisfy this:

- a front layer provider that terminates TLS inside Türkiye; or
- a TCP passthrough front layer that forwards encrypted traffic without opening it, so TLS ends only at your own proxy in the region.

A front layer that terminates TLS abroad, even only for DDoS filtering, is not acceptable for these tenants.

## CDN tunnels

A CDN tunnel, such as Cloudflare Tunnel, is an accepted way to publish the console, browser and subscriber traffic. It keeps the installation's IP address hidden, needs no open inbound port and brings the CDN's DDoS protection.

The price is that TLS ends at the CDN, which then sees request contents. If you choose a tunnel, write that down as the declared trust boundary of your installation. The leg from the tunnel to Relay must be encrypted again before it carries personal data or credentials, either with TLS at your proxy or with encryption in your cluster network.

The rule for regulated tenants in Türkiye takes precedence: their traffic never goes through a tunnel that can open TLS outside the country. Use a domestic front layer or TCP passthrough for them.

## Signatures are verified by Relay

Providers send delivery receipts and inbound messages to Relay as signed webhooks. Relay verifies those signatures itself, in the application, whatever sits in front of it. A WAF rule or CDN feature that claims to check signatures does not replace this, and you never need to configure one for Relay to be safe.

## Edge runtimes

Relay does not run on edge runtimes such as Cloudflare Workers. It needs long-lived connections, database transactions, persistent HTTP/2 connections to providers and region-bound data, none of which fit that model. An edge network can sit in front of Relay as described above, but Relay itself runs in the region.

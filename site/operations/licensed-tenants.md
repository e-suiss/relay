# Licensed tenants in Türkiye

Banks, payment institutions, e-money institutions and other organisations licensed in Türkiye often have to keep data in the country. This page describes the deployments that support such an obligation. Whether your licence actually requires it, and which of these deployments meets your regulator's expectations, is your assessment to make; Relay gives you the technical options.

## Two recommended deployments

**The Türkiye region of the hosted service.** It runs in Türkiye, keeps backups, key backups and telemetry in Türkiye, and is linked to the Access installation in the same region. See [Regions and data residency](./regions).

**A self-hosted installation with domestic providers.** You run Relay and Access in your own data centre or on a cloud in Türkiye, and you connect only providers that process data in Türkiye:

- SMS through a domestic SMS operator or aggregator authorised to carry commercial messages in Türkiye;
- email through a domestic email provider or your own mail transfer agent;
- web push, in-app messages and the realtime inbox, which need no third party at all.

In either deployment, follow the front layer rule for regulated tenants: TLS never ends outside Türkiye. See [Front layer and TLS](./front-layer).

## SMS to Turkish numbers

Messages to `+90` numbers go only through operators and aggregators authorised in Türkiye. Relay refuses to send a Turkish SMS over an international route when it carries a link, and when no domestic route is configured it stops rather than falling back to an international one.

## Push notifications on iOS

There is no way to deliver push notifications to iPhones and iPads without Apple Push Notification service (APNs). APNs is operated by Apple, outside Türkiye. If sending through APNs is not acceptable for your use, plan for iOS users to receive messages through the in-app inbox, SMS or email instead.

## Keys

If your policy requires it, keep your data keys under your own control with [bring your own key](./keys#bring-your-own-key). On a self-hosted installation you choose the HSM yourself.

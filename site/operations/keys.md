# Keys, HSM and BYOK

Relay never holds a key in plain text in its own memory or files. Signing keys, key-encryption keys and blind-index keys live in a hardware security module (HSM), and Relay reaches them only through PKCS#11, by way of a small native port program that runs next to each node. Private keys never leave the HSM in clear text.

## HSM policy

**The default is a cloud HSM reached over PKCS#11.** Every region uses a validated cloud HSM service through its PKCS#11 bridge. The service runs the hardware and takes care of availability, backups and firmware.

**A single-tenant HSM only when an auditor or regulator asks for it.** A dedicated HSM can restrict how keys are imported and adds real operational work: clustering, backups, firmware and on-site procedures. Relay therefore uses one only when an audit or regulation explicitly demands it.

Because both options are reached through the same PKCS#11 interface, moving from one to the other is a configuration change: a different PKCS#11 module, token and PIN file. No code changes. Locally, the compose stack uses SoftHSM through the same path.

Key backups follow the region: the Türkiye region keeps its key backups in Türkiye.

## How tenant data is encrypted

Each tenant has its own data keys. By default those data keys are wrapped by the region's key-encryption key, which lives in the region's HSM. Personal fields are encrypted with per-person keys under the tenant's keys, which is what makes erasing a person or closing a tenant possible by destroying keys rather than rewriting rows.

## Bring your own key

A tenant can ask for its data keys to be wrapped by a key it controls instead of the region's key.

- The tenant's key is a key label reserved for that tenant in the region's HSM, given to Relay as a PKCS#11 URI such as `pkcs11:token=tenant-hsm;object=acme-wrap`. Relay never sees the key material, only uses it through the HSM.
- Turning BYOK on, or changing the key, is an operation of the installation operator. It requires step-up authentication, is written to the audit log, and re-wraps the tenant's existing data keys under the new key.
- If the key cannot be reached, for example because the tenant disabled it, reads of the tenant's encrypted data fail closed: Relay refuses them instead of falling back to another key, and the `key_unavailable` alarm fires.
- If the tenant destroys its key, the result is the same as closing the tenant with crypto-shredding: everything encrypted under it becomes permanently unreadable.

Self-hosted installations use the same mechanism with the HSM of their choice.

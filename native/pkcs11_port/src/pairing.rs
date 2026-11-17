//! Access pairing: the checks of one pairing challenge, its intent digests recomputed with the Access kernel, and the Actor Intent Statements the service key signs as `COSE_Sign1`.

use std::collections::{BTreeMap, BTreeSet};

use access_kernel::ais::{self, Expected, Statement};
use access_kernel::codec::Canonical;
use access_kernel::combinator::{Capacity, Mode};
use access_kernel::digest::Digest;
use access_kernel::intent::{ContextRefs, IntentEnvelope, intent_digest};
use access_kernel::meta::{self, ActorKind, ExerciseBasis, Payload, Root};
use access_kernel::model::{ActionRef, Id, ResourceRef, Window};
use access_kernel::schema::{ActionSchema, EffectClass, action_digest};
use access_kernel::verify::cose::{self, Algorithm, PublicKey};
use access_kernel::verify::key_scope::thumbprint;
use esuiss_crypto::dcbor::{self, Limits, Value};

/// Least validity a challenge must have left to be signed, in milliseconds.
const MIN_VALIDITY_MS: u64 = 60_000;

/// Longest PEP name in bytes.
const MAX_PEP: usize = 255;

/// Appended to the challenge to form the `party_register` nonce.
const REGISTER_SUFFIX: u8 = 0x01;

/// Resource namespace a self-signed registration intent names its Party in.
const PARTY_NAMESPACE: &str = "access.party";

/// Intent parameter that carries the digest of the meta payload.
const PAYLOAD_PARAM: &str = "payload";

/// Index of the Genesis bootstrap Grant among the Genesis objects.
const BOOTSTRAP_GRANT: u64 = 0;

/// One Exercise of a challenge: its nonce and the intent digest Access computed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Exercise {
    pub nonce: Vec<u8>,
    pub intent: [u8; 32],
}

/// A pairing challenge of one Access environment as Access sent it, with the time of signing; times are Unix milliseconds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pairing {
    pub domain: [u8; 32],
    pub basis: [u8; 16],
    pub pep: String,
    pub party: [u8; 16],
    pub kid: [u8; 32],
    pub challenge: [u8; 32],
    pub valid_from: u64,
    pub valid_until: u64,
    pub now: u64,
    pub instance_create: Exercise,
    pub party_register: Option<Exercise>,
}

/// The check a challenge failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    Kid,
    Nonce,
    RegisterNonce,
    Validity,
    Pep,
    Basis,
    InstanceIntent,
    RegisterIntent,
    Encoding,
    Signature,
}

impl Refusal {
    /// The stable code sent back for the refusal.
    pub const fn code(self) -> &'static str {
        match self {
            Refusal::Kid => "pairing-kid",
            Refusal::Nonce => "pairing-nonce",
            Refusal::RegisterNonce => "pairing-register-nonce",
            Refusal::Validity => "pairing-validity",
            Refusal::Pep => "pairing-pep",
            Refusal::Basis => "pairing-basis",
            Refusal::InstanceIntent => "pairing-instance-intent",
            Refusal::RegisterIntent => "pairing-register-intent",
            Refusal::Encoding => "pairing-encoding",
            Refusal::Signature => "pairing-signature",
        }
    }
}

/// A challenge that was not signed: a check refused it, or the signer failed.
#[derive(Debug)]
pub enum Error<E> {
    Refused(Refusal),
    Signer(E),
}

struct Unsigned {
    nonce: Vec<u8>,
    intent: Digest,
    protected: Vec<u8>,
    payload: Vec<u8>,
}

/// Signs the statements of `pairing` for the service key `key`: `instance_create` first, then `party_register` when the challenge names it, each a tagged `COSE_Sign1` whose `Sig_structure` went through `signer`. Every check of every statement runs before the first signature, so a refused challenge reaches the signer with nothing, and a statement the kernel does not verify under `key` is not returned.
pub fn sign<E>(
    pairing: &Pairing,
    key: [u8; 32],
    mut signer: impl FnMut(&[u8]) -> Result<Vec<u8>, E>,
) -> Result<Vec<Vec<u8>>, Error<E>> {
    let public = PublicKey::Ed25519(key);
    let statements = check(pairing, &public).map_err(Error::Refused)?;
    let mut signed = Vec::with_capacity(statements.len());
    for unsigned in &statements {
        let message = cose::to_be_signed(&unsigned.protected, &unsigned.payload);
        let signature = signer(&message).map_err(Error::Signer)?;
        let sign1 = assemble(unsigned, &signature).ok_or(Error::Refused(Refusal::Encoding))?;
        if !verified(pairing, &public, unsigned, &sign1) {
            return Err(Error::Refused(Refusal::Signature));
        }
        signed.push(sign1);
    }
    Ok(signed)
}

fn check(pairing: &Pairing, public: &PublicKey) -> Result<Vec<Unsigned>, Refusal> {
    if public.check().is_err() || thumbprint(public) != pairing.kid {
        return Err(Refusal::Kid);
    }
    if pairing.instance_create.nonce != pairing.challenge {
        return Err(Refusal::Nonce);
    }
    if let Some(register) = &pairing.party_register {
        let mut nonce = pairing.challenge.to_vec();
        nonce.push(REGISTER_SUFFIX);
        if register.nonce != nonce {
            return Err(Refusal::RegisterNonce);
        }
    }
    let left = pairing.valid_until.checked_sub(pairing.now);
    if pairing.valid_from > pairing.valid_until || left.is_none_or(|ms| ms < MIN_VALIDITY_MS) {
        return Err(Refusal::Validity);
    }
    if pairing.pep.is_empty() || pairing.pep.len() > MAX_PEP {
        return Err(Refusal::Pep);
    }
    if bootstrap_basis(&Digest(pairing.domain)) != Id(pairing.basis) {
        return Err(Refusal::Basis);
    }
    let party = Id(pairing.party);
    let exercise = &pairing.instance_create;
    let payload = create_payload(party, public);
    let create = unsigned(pairing, exercise, &payload, Refusal::InstanceIntent)?;
    let mut statements = vec![create];
    if let Some(exercise) = &pairing.party_register {
        let payload = register_payload(party);
        let register = unsigned(pairing, exercise, &payload, Refusal::RegisterIntent)?;
        statements.push(register);
    }
    Ok(statements)
}

fn unsigned(
    pairing: &Pairing,
    exercise: &Exercise,
    payload: &Payload,
    mismatch: Refusal,
) -> Result<Unsigned, Refusal> {
    let validity = Window {
        from: pairing.valid_from,
        until: pairing.valid_until,
    };
    let intent = intent(payload, Id(pairing.party), validity).ok_or(Refusal::Encoding)?;
    if intent.0 != exercise.intent {
        return Err(mismatch);
    }
    let statement = Statement {
        domain: Digest(pairing.domain),
        nonce: exercise.nonce.clone(),
        intent,
        mode: Mode::Commit,
        pep: pairing.pep.clone(),
        capacity: Capacity::Own,
        basis: ExerciseBasis::Public(Id(pairing.basis)),
        iat: pairing.now,
        exercise: None,
    };
    Ok(Unsigned {
        nonce: exercise.nonce.clone(),
        intent,
        protected: protected(pairing.kid).ok_or(Refusal::Encoding)?,
        payload: statement.to_bytes().map_err(|_| Refusal::Encoding)?,
    })
}

fn verified(pairing: &Pairing, public: &PublicKey, unsigned: &Unsigned, sign1: &[u8]) -> bool {
    let domain = Digest(pairing.domain);
    let basis = ExerciseBasis::Public(Id(pairing.basis));
    let expected = Expected {
        domain: &domain,
        nonce: &unsigned.nonce,
        intent: &unsigned.intent,
        mode: Mode::Commit,
        pep: &pairing.pep,
        capacity: Capacity::Own,
        basis: &basis,
        exercise: None,
    };
    ais::verify(sign1, public, &expected, pairing.now).is_ok()
}

fn bootstrap_basis(domain: &Digest) -> Id {
    meta::object_id(domain, meta::kind::GRANT, BOOTSTRAP_GRANT)
}

fn create_payload(party: Id, key: &PublicKey) -> Payload {
    Payload::InstanceCreate {
        party,
        key: key.clone(),
        mandate: None,
    }
}

fn register_payload(party: Id) -> Payload {
    Payload::PartyRegister {
        party,
        root: Root::Sole(party),
        actor_kind: ActorKind::System,
    }
}

fn core_action(name: &str) -> ActionRef {
    let schema = ActionSchema {
        name: name.to_string(),
        major: 1,
        effect: EffectClass::Reversible,
        reserved: false,
        consumption_bearing: false,
        params: BTreeMap::new(),
        resource_types: BTreeSet::new(),
        render: None,
    };
    ActionRef {
        namespace: meta::NAMESPACE.to_string(),
        name: name.to_string(),
        major: 1,
        schema: action_digest(&schema),
    }
}

fn intent(payload: &Payload, party: Id, validity: Window) -> Option<Digest> {
    let resource = ResourceRef {
        namespace: PARTY_NAMESPACE.to_string(),
        path: vec![hex(&party.0)],
        incarnation: 0,
    };
    let digest = payload.digest().ok()?;
    let envelope = IntentEnvelope {
        action: core_action(payload.action()),
        resources: vec![resource],
        params: BTreeMap::new(),
        opaque: BTreeMap::from([(PAYLOAD_PARAM.to_string(), digest)]),
        recipient: None,
        purpose: None,
        context: ContextRefs::default(),
        validity,
    };
    intent_digest(&envelope).ok()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn protected(kid: [u8; 32]) -> Option<Vec<u8>> {
    let alg = Value::int(Algorithm::Ed25519.cose());
    let content_type = Value::text(ais::CONTENT_TYPE);
    let header = Value::Map(vec![
        (Value::Unsigned(cose::ALG), alg),
        (Value::Unsigned(cose::CONTENT_TYPE), content_type),
        (Value::Unsigned(cose::KID), Value::Bytes(kid.to_vec())),
    ]);
    dcbor::encode(&header, Limits::CEILING).ok()
}

fn assemble(unsigned: &Unsigned, signature: &[u8]) -> Option<Vec<u8>> {
    let body = Value::Array(vec![
        Value::Bytes(unsigned.protected.clone()),
        Value::Map(Vec::new()),
        Value::Bytes(unsigned.payload.clone()),
        Value::Bytes(signature.to_vec()),
    ]);
    let mut out = vec![0xd2];
    out.extend(dcbor::encode(&body, Limits::CEILING).ok()?);
    Some(out)
}

#[cfg(test)]
mod tests {
    use ed25519_dalek::{Signature, Signer, SigningKey};

    use super::*;

    const SEED: &str = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60";
    const KEY: &str = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a";
    const KID: &str = "90facafea9b1556698540f70c0117a22ea37bd5cf3ed3c47093c1707282b4b89";
    const BASIS: &str = "dbc752a072af3666687ff3843115056d";
    const CREATE_INTENT: &str = "9f402bc9c95a8f212916dce044a03bb8f8e12227c531a4e8e2dcb13fc9661bbf";
    const REGISTER_INTENT: &str =
        "8bd4510b2870dca8a2df9876dc12f333bb08c9e0755be7844026c1357df53278";
    const AIS: &str = concat!(
        "d2845844a3013203781b6170706c69636174696f6e2f6163636573732d6169732b63626f72",
        "04582090facafea9b1556698540f70c0117a22ea37bd5cf3ed3c47093c1707282b4b89a058",
        "d8a8636961741b000001a1b2bc7e60637065706f6163636573732d6964656e74697479646d",
        "6f646566636f6d6d6974656261736973a1667075626c696350dbc752a072af3666687ff384",
        "3115056d656e6f6e6365582033333333333333333333333333333333333333333333333333",
        "3333333333333366646f6d61696e822f582022222222222222222222222222222222222222",
        "2222222222222222222222222266696e74656e74822f58209f402bc9c95a8f212916dce044",
        "a03bb8f8e12227c531a4e8e2dcb13fc9661bbf686361706163697479636f776e584015068c",
        "0f5dc9e8840b3b07119ddadcf129124093aa6f5d6966d5ba51d356b4497906edccfec60cca",
        "b51f664e0c59aadb8d3eb9fac9596ef4fd5992b0f9eab201",
    );
    const REGISTER_AIS: &str = concat!(
        "d2845844a3013203781b6170706c69636174696f6e2f6163636573732d6169732b63626f72",
        "04582090facafea9b1556698540f70c0117a22ea37bd5cf3ed3c47093c1707282b4b89a058",
        "d9a8636961741b000001a1b2bc7e60637065706f6163636573732d6964656e74697479646d",
        "6f646566636f6d6d6974656261736973a1667075626c696350dbc752a072af3666687ff384",
        "3115056d656e6f6e6365582133333333333333333333333333333333333333333333333333",
        "333333333333330166646f6d61696e822f5820222222222222222222222222222222222222",
        "222222222222222222222222222266696e74656e74822f58208bd4510b2870dca8a2df9876",
        "dc12f333bb08c9e0755be7844026c1357df53278686361706163697479636f776e5840848f",
        "747b875ca2372303630ea5994191bb3c0b0d7dff84c7f6e94a87a2f8a91ab0322044b3d4e4",
        "63efe7037fea504ea4b10e8252975f908e0791fb3c220cd305",
    );
    const PEP: &str = "access-identity";
    const FROM: u64 = 1_794_000_000_000;
    const UNTIL: u64 = 1_794_000_600_000;
    const NOW: u64 = 1_794_000_060_000;

    fn unhex(text: &str) -> Vec<u8> {
        (0..text.len())
            .step_by(2)
            .map(|at| u8::from_str_radix(&text[at..at + 2], 16).unwrap())
            .collect()
    }

    fn signing_key() -> SigningKey {
        SigningKey::from_bytes(&unhex(SEED).try_into().unwrap())
    }

    fn key() -> [u8; 32] {
        signing_key().verifying_key().to_bytes()
    }

    fn validity() -> Window {
        Window {
            from: FROM,
            until: UNTIL,
        }
    }

    fn challenge() -> Pairing {
        let public = PublicKey::Ed25519(key());
        let domain = Digest([0x22; 32]);
        let party = Id([0x11; 16]);
        let create = intent(&create_payload(party, &public), party, validity()).unwrap();
        let register = intent(&register_payload(party), party, validity()).unwrap();
        let mut register_nonce = vec![0x33; 32];
        register_nonce.push(0x01);
        Pairing {
            domain: domain.0,
            basis: bootstrap_basis(&domain).0,
            pep: PEP.to_string(),
            party: party.0,
            kid: thumbprint(&public),
            challenge: [0x33; 32],
            valid_from: FROM,
            valid_until: UNTIL,
            now: NOW,
            instance_create: Exercise {
                nonce: vec![0x33; 32],
                intent: create.0,
            },
            party_register: Some(Exercise {
                nonce: register_nonce,
                intent: register.0,
            }),
        }
    }

    fn rechallenge(mut pairing: Pairing) -> Pairing {
        let public = PublicKey::Ed25519(key());
        let party = Id(pairing.party);
        let validity = Window {
            from: pairing.valid_from,
            until: pairing.valid_until,
        };
        let create = intent(&create_payload(party, &public), party, validity).unwrap();
        let register = intent(&register_payload(party), party, validity).unwrap();
        pairing.basis = bootstrap_basis(&Digest(pairing.domain)).0;
        pairing.instance_create.intent = create.0;
        pairing.party_register.as_mut().unwrap().intent = register.0;
        pairing
    }

    fn signed(pairing: &Pairing) -> Result<Vec<Vec<u8>>, Error<&'static str>> {
        let signing = signing_key();
        sign(pairing, key(), |message| {
            let signature: Signature = signing.sign(message);
            Ok(signature.to_bytes().to_vec())
        })
    }

    fn refused(pairing: &Pairing) -> Refusal {
        let mut calls = 0;
        let result = sign(pairing, key(), |_| {
            calls += 1;
            Err::<Vec<u8>, &'static str>("signed")
        });
        assert_eq!(calls, 0);
        refusal(result).unwrap()
    }

    fn refusal<E>(result: Result<Vec<Vec<u8>>, Error<E>>) -> Option<Refusal> {
        match result {
            Err(Error::Refused(refusal)) => Some(refusal),
            _ => None,
        }
    }

    fn expected<'a>(
        domain: &'a Digest,
        basis: &'a ExerciseBasis,
        nonce: &'a [u8],
        intent: &'a Digest,
    ) -> Expected<'a> {
        Expected {
            domain,
            nonce,
            intent,
            mode: Mode::Commit,
            pep: PEP,
            capacity: Capacity::Own,
            basis,
            exercise: None,
        }
    }

    #[test]
    fn e_101_recomputes_the_digests_of_a_known_challenge() {
        let pairing = challenge();
        assert_eq!(hex(&key()), KEY);
        assert_eq!(hex(&pairing.kid), KID);
        assert_eq!(hex(&pairing.basis), BASIS);
        assert_eq!(hex(&pairing.instance_create.intent), CREATE_INTENT);
        let register = pairing.party_register.unwrap();
        assert_eq!(hex(&register.intent), REGISTER_INTENT);
    }

    #[test]
    fn e_101_signs_the_statements_of_a_known_challenge() {
        let signed = signed(&challenge()).unwrap();
        assert_eq!(signed.len(), 2);
        assert_eq!(hex(&signed[0]), AIS);
        assert_eq!(hex(&signed[1]), REGISTER_AIS);
    }

    #[test]
    fn e_101_the_kernel_verifies_each_statement_under_the_service_key() {
        let pairing = challenge();
        let signed = signed(&pairing).unwrap();
        let public = PublicKey::Ed25519(key());
        let domain = Digest(pairing.domain);
        let basis = ExerciseBasis::Public(Id(pairing.basis));
        let register = pairing.party_register.clone().unwrap();
        let exercises = [
            (&pairing.instance_create, &signed[0]),
            (&register, &signed[1]),
        ];
        for (exercise, sign1) in exercises {
            let intent = Digest(exercise.intent);
            let expected = expected(&domain, &basis, &exercise.nonce, &intent);
            let statement = ais::verify(sign1, &public, &expected, NOW).unwrap();
            assert_eq!(statement.mode, Mode::Commit);
            assert_eq!(statement.capacity, Capacity::Own);
            assert_eq!(statement.iat, NOW);
            assert_eq!(statement.exercise, None);
            let message = cose::parse_sign1(sign1).unwrap();
            let header = dcbor::decode(&message.protected, Limits::CEILING).unwrap();
            let members = vec![
                (Value::Unsigned(1), Value::int(-19)),
                (Value::Unsigned(3), Value::text(ais::CONTENT_TYPE)),
                (Value::Unsigned(4), Value::Bytes(pairing.kid.to_vec())),
            ];
            assert_eq!(header, Value::Map(members));
            assert_eq!(ais::CONTENT_TYPE, "application/access-ais+cbor");
        }
    }

    #[test]
    fn e_101_signs_only_instance_create_for_a_registered_party() {
        let mut pairing = challenge();
        pairing.party_register = None;
        let signed = signed(&pairing).unwrap();
        assert_eq!(signed.len(), 1);
        assert_eq!(hex(&signed[0]), AIS);
    }

    #[test]
    fn e_101_refuses_a_kid_that_is_not_the_thumbprint_of_the_service_key() {
        let mut pairing = challenge();
        pairing.kid[0] ^= 1;
        assert_eq!(refused(&pairing), Refusal::Kid);
        let other = SigningKey::from_bytes(&[7; 32]);
        let other = other.verifying_key().to_bytes();
        let result = sign(&challenge(), other, |_| Err::<Vec<u8>, ()>(()));
        assert_eq!(refusal(result), Some(Refusal::Kid));
    }

    #[test]
    fn e_101_refuses_nonces_that_are_not_the_challenge() {
        let mut pairing = challenge();
        pairing.instance_create.nonce[0] ^= 1;
        assert_eq!(refused(&pairing), Refusal::Nonce);
        let mut pairing = challenge();
        pairing.instance_create.nonce.push(0x01);
        assert_eq!(refused(&pairing), Refusal::Nonce);
        let mut pairing = challenge();
        pairing.party_register.as_mut().unwrap().nonce[32] = 0x02;
        assert_eq!(refused(&pairing), Refusal::RegisterNonce);
        let mut pairing = challenge();
        pairing.party_register.as_mut().unwrap().nonce.pop();
        assert_eq!(refused(&pairing), Refusal::RegisterNonce);
    }

    #[test]
    fn e_101_refuses_less_than_sixty_seconds_of_validity() {
        let mut pairing = challenge();
        pairing.now = UNTIL - 59_999;
        assert_eq!(refused(&pairing), Refusal::Validity);
        pairing.now = UNTIL + 1;
        assert_eq!(refused(&pairing), Refusal::Validity);
        pairing.now = UNTIL - 60_000;
        assert_eq!(signed(&pairing).unwrap().len(), 2);
        let mut pairing = challenge();
        pairing.valid_from = UNTIL + 1;
        assert_eq!(refused(&pairing), Refusal::Validity);
    }

    #[test]
    fn e_101_refuses_a_pep_name_outside_one_to_255_bytes() {
        let mut pairing = challenge();
        pairing.pep = String::new();
        assert_eq!(refused(&pairing), Refusal::Pep);
        pairing.pep = "p".repeat(256);
        assert_eq!(refused(&pairing), Refusal::Pep);
        pairing.pep = "p".repeat(255);
        assert_eq!(signed(&pairing).unwrap().len(), 2);
    }

    #[test]
    fn e_101_refuses_a_basis_that_is_not_the_bootstrap_grant_of_the_domain() {
        let mut pairing = challenge();
        pairing.basis[0] ^= 1;
        assert_eq!(refused(&pairing), Refusal::Basis);
        let mut pairing = challenge();
        pairing.domain[0] ^= 1;
        assert_eq!(refused(&pairing), Refusal::Basis);
        assert_eq!(signed(&rechallenge(pairing)).unwrap().len(), 2);
    }

    #[test]
    fn e_101_refuses_an_intent_digest_the_kernel_does_not_recompute() {
        let mut pairing = challenge();
        pairing.instance_create.intent[0] ^= 1;
        assert_eq!(refused(&pairing), Refusal::InstanceIntent);
        let mut pairing = challenge();
        pairing.party_register.as_mut().unwrap().intent[31] ^= 1;
        assert_eq!(refused(&pairing), Refusal::RegisterIntent);
        let mut pairing = challenge();
        pairing.valid_until += 1;
        assert_eq!(refused(&pairing), Refusal::InstanceIntent);
        assert_eq!(signed(&rechallenge(pairing)).unwrap().len(), 2);
        let mut pairing = challenge();
        pairing.party[0] ^= 1;
        assert_eq!(refused(&pairing), Refusal::InstanceIntent);
        assert_eq!(signed(&rechallenge(pairing)).unwrap().len(), 2);
        let mut pairing = challenge();
        let register = pairing.party_register.clone().unwrap();
        pairing.instance_create.intent = register.intent;
        assert_eq!(refused(&pairing), Refusal::InstanceIntent);
    }

    #[test]
    fn e_101_returns_nothing_the_kernel_does_not_verify() {
        let result = sign(&challenge(), key(), |_| Ok::<_, ()>(vec![0; 64]));
        assert_eq!(refusal(result), Some(Refusal::Signature));
        let other = SigningKey::from_bytes(&[7; 32]);
        let result = sign(&challenge(), key(), |message| {
            let signature: Signature = other.sign(message);
            Ok::<_, ()>(signature.to_bytes().to_vec())
        });
        assert_eq!(refusal(result), Some(Refusal::Signature));
        let result = sign(&challenge(), key(), |_| Err::<Vec<u8>, _>("token"));
        assert!(matches!(result, Err(Error::Signer("token"))));
    }
}

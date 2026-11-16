//! Token operations behind the protocol: signing, public key export, AES-256-GCM key wrapping under a KEK, HMAC-SHA256 under a secret key, reading secret data objects, generating secret keys that never leave the token, and Ed25519 keys that leave it only wrapped under a wrapping key and sign after being unwrapped inside it.

use cryptoki::context::{CInitializeArgs, CInitializeFlags, Pkcs11};
use cryptoki::error::{Error, RvError};
use cryptoki::mechanism::Mechanism;
use cryptoki::mechanism::aead::GcmParams;
use cryptoki::mechanism::eddsa::{EddsaParams, EddsaSignatureScheme};
use cryptoki::object::{Attribute, AttributeType, KeyType, ObjectClass, ObjectHandle};
use cryptoki::session::{Session, UserType};
use cryptoki::slot::Slot;
use cryptoki::types::AuthPin;
use zeroize::Zeroizing;

use crate::der;
use crate::protocol::{Alg, KeyKind, Status};

/// GCM nonce length in bytes.
pub const IV_LEN: usize = 12;

/// GCM tag length in bytes.
pub const TAG_LEN: usize = 16;

/// HMAC-SHA256 output length in bytes.
pub const HMAC_LEN: usize = 32;

/// Length in bytes of every generated secret key.
pub const KEY_LEN: u64 = 32;

/// Length in bytes of an Ed25519 public key.
pub const ED25519_LEN: usize = 32;

/// The Ed25519 curve parameters as the curve name and as the object identifier 1.3.101.112.
const ED25519_PARAMS: [&[u8]; 2] = [
    &[
        0x13, 0x0c, b'e', b'd', b'w', b'a', b'r', b'd', b's', b'2', b'5', b'5', b'1', b'9',
    ],
    &[0x06, 0x03, 0x2b, 0x65, 0x70],
];

/// A failed operation: the status sent back, a message without key material, and whether the session is lost.
#[derive(Debug)]
pub struct Failure {
    pub status: Status,
    pub message: String,
    pub fatal: bool,
}

impl Failure {
    fn new(status: Status, message: &str) -> Self {
        Failure {
            status,
            message: message.to_string(),
            fatal: false,
        }
    }
}

impl From<Error> for Failure {
    fn from(error: Error) -> Self {
        match error {
            Error::Pkcs11(rv, function) => {
                let status = match rv {
                    RvError::EncryptedDataInvalid | RvError::EncryptedDataLenRange => {
                        Status::Integrity
                    }
                    _ => Status::Token,
                };
                Failure {
                    status,
                    message: format!("{function:?}: {rv:?}"),
                    fatal: fatal(rv),
                }
            }
            other => Failure {
                status: Status::Internal,
                message: format!("cryptoki: {other}"),
                fatal: false,
            },
        }
    }
}

fn fatal(rv: RvError) -> bool {
    matches!(
        rv,
        RvError::SessionHandleInvalid
            | RvError::SessionClosed
            | RvError::DeviceRemoved
            | RvError::DeviceError
            | RvError::TokenNotPresent
            | RvError::UserNotLoggedIn
            | RvError::CryptokiNotInitialized
    )
}

/// A logged-in session on the configured token.
pub struct Hsm {
    session: Session,
    slot: Slot,
    context: Pkcs11,
}

impl Hsm {
    /// Loads the module, finds the token by label and logs in as the user.
    pub fn open(module: &str, token: &str, pin: AuthPin) -> Result<Self, Failure> {
        let context = Pkcs11::new(module)?;
        context.initialize(CInitializeArgs::new(CInitializeFlags::OS_LOCKING_OK))?;
        let slot = context
            .get_slots_with_token()?
            .into_iter()
            .find(|slot| {
                context
                    .get_token_info(*slot)
                    .map(|info| info.label() == token)
                    .unwrap_or(false)
            })
            .ok_or_else(|| Failure::new(Status::NotFound, "token not found"))?;
        let session = context.open_ro_session(slot)?;
        match session.login(UserType::User, Some(&pin)) {
            Ok(()) | Err(Error::Pkcs11(RvError::UserAlreadyLoggedIn, _)) => {}
            Err(error) => return Err(error.into()),
        }
        Ok(Hsm {
            session,
            slot,
            context,
        })
    }

    /// Confirms the session is usable.
    pub fn ping(&self) -> Result<(), Failure> {
        self.session.get_session_info()?;
        Ok(())
    }

    /// Signs `message` with the private key labelled `label`. ECDSA output is `R‖S`.
    pub fn sign(&self, alg: Alg, label: &[u8], message: &[u8]) -> Result<Vec<u8>, Failure> {
        let key = self.find(ObjectClass::PRIVATE_KEY, key_type(alg), label)?;
        match alg {
            Alg::Es256 => {
                let digest = self.session.digest(&Mechanism::Sha256, message)?;
                let signature = self.session.sign(&Mechanism::Ecdsa, key, &digest)?;
                der::ecdsa_raw(&signature, der::P256_SCALAR)
                    .ok_or_else(|| Failure::new(Status::Token, "unexpected ECDSA signature form"))
            }
            Alg::Rs256 => Ok(self.session.sign(&Mechanism::Sha256RsaPkcs, key, message)?),
            Alg::Ed25519 => {
                let params = EddsaParams::new(EddsaSignatureScheme::Ed25519);
                Ok(self.session.sign(&Mechanism::Eddsa(params), key, message)?)
            }
        }
    }

    /// Returns the public key labelled `label`: the uncompressed point for ES256, the 32-byte key for Ed25519, modulus and exponent for RS256.
    pub fn public_key(&self, alg: Alg, label: &[u8]) -> Result<Vec<Vec<u8>>, Failure> {
        let key = self.find(ObjectClass::PUBLIC_KEY, key_type(alg), label)?;
        match alg {
            Alg::Es256 | Alg::Ed25519 => {
                let len = if alg == Alg::Es256 { 65 } else { 32 };
                let value = self.attribute(key, AttributeType::EcPoint)?;
                der::ec_point(&value, len)
                    .map(|point| vec![point])
                    .ok_or_else(|| Failure::new(Status::Token, "unexpected EC point form"))
            }
            Alg::Rs256 => Ok(vec![
                self.attribute(key, AttributeType::Modulus)?,
                self.attribute(key, AttributeType::PublicExponent)?,
            ]),
        }
    }

    /// Encrypts `plaintext` under the AES KEK labelled `label`; returns `IV‖ciphertext‖tag`.
    pub fn wrap(&self, label: &[u8], aad: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, Failure> {
        let key = self.find(ObjectClass::SECRET_KEY, KeyType::AES, label)?;
        let mut iv = [0u8; IV_LEN];
        self.session.generate_random_slice(&mut iv)?;
        let mut out = iv.to_vec();
        let params = GcmParams::new(&mut iv, aad, (8 * TAG_LEN as u64).into())?;
        let ciphertext = self
            .session
            .encrypt(&Mechanism::AesGcm(params), key, plaintext)?;
        out.extend_from_slice(&ciphertext);
        Ok(out)
    }

    /// Reverses `wrap`; a wrong KEK, AAD or tampered input fails with `Integrity`.
    pub fn unwrap(
        &self,
        label: &[u8],
        aad: &[u8],
        wrapped: &[u8],
    ) -> Result<Zeroizing<Vec<u8>>, Failure> {
        if wrapped.len() < IV_LEN + TAG_LEN {
            return Err(Failure::new(Status::Integrity, "wrapped key too short"));
        }
        let key = self.find(ObjectClass::SECRET_KEY, KeyType::AES, label)?;
        let (iv, ciphertext) = wrapped.split_at(IV_LEN);
        let mut iv: [u8; IV_LEN] = iv
            .try_into()
            .map_err(|_| Failure::new(Status::Internal, "iv"))?;
        let params = GcmParams::new(&mut iv, aad, (8 * TAG_LEN as u64).into())?;
        match self
            .session
            .decrypt(&Mechanism::AesGcm(params), key, ciphertext)
        {
            Ok(plaintext) => Ok(Zeroizing::new(plaintext)),
            Err(Error::Pkcs11(RvError::FunctionFailed | RvError::GeneralError, _)) => Err(
                Failure::new(Status::Integrity, "wrapped key failed authentication"),
            ),
            Err(error) => Err(error.into()),
        }
    }

    /// Computes HMAC-SHA256 of `message` under the generic secret or HMAC key labelled `label`; the key never leaves the token.
    pub fn hmac(&self, label: &[u8], message: &[u8]) -> Result<Vec<u8>, Failure> {
        let key = match self.find(ObjectClass::SECRET_KEY, KeyType::GENERIC_SECRET, label) {
            Err(failure) if failure.status == Status::NotFound => {
                self.find(ObjectClass::SECRET_KEY, KeyType::SHA256_HMAC, label)?
            }
            found => found?,
        };
        let mac = self.session.sign(&Mechanism::Sha256Hmac, key, message)?;
        if mac.len() == HMAC_LEN {
            Ok(mac)
        } else {
            Err(Failure::new(Status::Token, "unexpected HMAC length"))
        }
    }

    /// Returns the value of the data object labelled `label`.
    pub fn read_secret(&self, label: &[u8]) -> Result<Zeroizing<Vec<u8>>, Failure> {
        let template = [
            Attribute::Class(ObjectClass::DATA),
            Attribute::Label(label.to_vec()),
        ];
        let object = self.unique(&template)?;
        let attributes = self
            .session
            .get_attributes(object, &[AttributeType::Value])?;
        attributes
            .into_iter()
            .find_map(|attribute| match attribute {
                Attribute::Value(value) => Some(Zeroizing::new(value)),
                _ => None,
            })
            .ok_or_else(|| Failure::new(Status::Token, "attribute missing"))
    }

    /// Generates a 256-bit token secret key labelled `label` with CKA_ID `id`: sensitive, never extractable, private and usable only for its purpose. A label already in use is refused with `Exists`.
    pub fn generate_key(&self, kind: KeyKind, label: &[u8], id: &[u8]) -> Result<(), Failure> {
        let taken = self.session.find_objects(&[
            Attribute::Class(ObjectClass::SECRET_KEY),
            Attribute::Label(label.to_vec()),
        ])?;
        if !taken.is_empty() {
            return Err(Failure::new(Status::Exists, "key label already exists"));
        }
        let (mechanism, key_type, encrypt, sign, wrap) = match kind {
            KeyKind::Aes256 => (Mechanism::AesKeyGen, KeyType::AES, true, false, false),
            KeyKind::HmacSha256 => (
                Mechanism::GenericSecretKeyGen,
                KeyType::GENERIC_SECRET,
                false,
                true,
                false,
            ),
            KeyKind::Aes256Wrap => (Mechanism::AesKeyGen, KeyType::AES, false, false, true),
        };
        let template = [
            Attribute::Class(ObjectClass::SECRET_KEY),
            Attribute::KeyType(key_type),
            Attribute::ValueLen(KEY_LEN.into()),
            Attribute::Token(true),
            Attribute::Private(true),
            Attribute::Sensitive(true),
            Attribute::Extractable(false),
            Attribute::Encrypt(encrypt),
            Attribute::Decrypt(encrypt),
            Attribute::Sign(sign),
            Attribute::Verify(sign),
            Attribute::Wrap(wrap),
            Attribute::Unwrap(wrap),
            Attribute::Derive(false),
            Attribute::Label(label.to_vec()),
            Attribute::Id(id.to_vec()),
        ];
        let session = self.context.open_rw_session(self.slot)?;
        session.generate_key(&mechanism, &template)?;
        Ok(())
    }

    /// Stores `value` as a private, unmodifiable token data object labelled `label`, which `read_secret` reads back. A label already in use is refused with `Exists`.
    pub fn store_secret(&self, label: &[u8], value: &[u8]) -> Result<(), Failure> {
        let taken = self.session.find_objects(&[
            Attribute::Class(ObjectClass::DATA),
            Attribute::Label(label.to_vec()),
        ])?;
        if !taken.is_empty() {
            return Err(Failure::new(Status::Exists, "secret label already exists"));
        }
        let template = [
            Attribute::Class(ObjectClass::DATA),
            Attribute::Token(true),
            Attribute::Private(true),
            Attribute::Modifiable(false),
            Attribute::Label(label.to_vec()),
            Attribute::Value(value.to_vec()),
        ];
        let session = self.context.open_rw_session(self.slot)?;
        session.create_object(&template)?;
        Ok(())
    }

    /// Generates an Ed25519 key pair as session objects and returns the private key wrapped under the AES wrapping key labelled `label`, with the 32-byte public key. The private key exists unwrapped only inside the token.
    pub fn generate_wrapped(&self, label: &[u8]) -> Result<(Vec<u8>, Vec<u8>), Failure> {
        let wrapping = self.find(ObjectClass::SECRET_KEY, KeyType::AES, label)?;
        let (public, private) = self.ed25519_pair()?;
        let result = self.export_pair(wrapping, public, private);
        let _ = self.session.destroy_object(private);
        let _ = self.session.destroy_object(public);
        result
    }

    /// Unwraps an Ed25519 private key produced by `generate_wrapped` inside the token as a session object that cannot be extracted, signs `message` with it and destroys it. A wrong wrapping key or a tampered input fails with `Integrity`.
    pub fn sign_wrapped(
        &self,
        label: &[u8],
        wrapped: &[u8],
        message: &[u8],
    ) -> Result<Vec<u8>, Failure> {
        let wrapping = self.find(ObjectClass::SECRET_KEY, KeyType::AES, label)?;
        let template = [
            Attribute::Class(ObjectClass::PRIVATE_KEY),
            Attribute::KeyType(KeyType::EC_EDWARDS),
            Attribute::Token(false),
            Attribute::Private(true),
            Attribute::Sensitive(true),
            Attribute::Extractable(false),
            Attribute::Sign(true),
        ];
        let key = self
            .session
            .unwrap_key(&Mechanism::AesKeyWrapPad, wrapping, wrapped, &template)
            .map_err(unwrap_failure)?;
        let params = EddsaParams::new(EddsaSignatureScheme::Ed25519);
        let signature = self.session.sign(&Mechanism::Eddsa(params), key, message);
        let _ = self.session.destroy_object(key);
        Ok(signature?)
    }

    fn ed25519_pair(&self) -> Result<(ObjectHandle, ObjectHandle), Failure> {
        let mut last = Failure::new(Status::Internal, "no curve parameters");
        for params in ED25519_PARAMS {
            let public = [
                Attribute::Token(false),
                Attribute::Verify(true),
                Attribute::EcParams(params.to_vec()),
            ];
            let private = [
                Attribute::Token(false),
                Attribute::Private(true),
                Attribute::Sensitive(true),
                Attribute::Extractable(true),
                Attribute::Sign(true),
            ];
            match self
                .session
                .generate_key_pair(&Mechanism::EccEdwardsKeyPairGen, &public, &private)
            {
                Ok(pair) => return Ok(pair),
                Err(error) => last = error.into(),
            }
        }
        Err(last)
    }

    fn export_pair(
        &self,
        wrapping: ObjectHandle,
        public: ObjectHandle,
        private: ObjectHandle,
    ) -> Result<(Vec<u8>, Vec<u8>), Failure> {
        let wrapped = self
            .session
            .wrap_key(&Mechanism::AesKeyWrapPad, wrapping, private)?;
        let value = self.attribute(public, AttributeType::EcPoint)?;
        let point = der::ec_point(&value, ED25519_LEN)
            .ok_or_else(|| Failure::new(Status::Token, "unexpected EC point form"))?;
        Ok((wrapped, point))
    }

    fn find(
        &self,
        class: ObjectClass,
        key_type: KeyType,
        label: &[u8],
    ) -> Result<ObjectHandle, Failure> {
        let template = [
            Attribute::Class(class),
            Attribute::KeyType(key_type),
            Attribute::Label(label.to_vec()),
        ];
        self.unique(&template)
    }

    fn unique(&self, template: &[Attribute]) -> Result<ObjectHandle, Failure> {
        let mut found = self.session.find_objects(template)?;
        match (found.pop(), found.is_empty()) {
            (Some(handle), true) => Ok(handle),
            (Some(_), false) => Err(Failure::new(Status::NotFound, "key label is not unique")),
            (None, _) => Err(Failure::new(Status::NotFound, "key not found")),
        }
    }

    fn attribute(&self, key: ObjectHandle, kind: AttributeType) -> Result<Vec<u8>, Failure> {
        let attributes = self.session.get_attributes(key, &[kind])?;
        attributes
            .into_iter()
            .find_map(|attribute| match attribute {
                Attribute::EcPoint(value)
                | Attribute::Modulus(value)
                | Attribute::PublicExponent(value) => Some(value),
                _ => None,
            })
            .ok_or_else(|| Failure::new(Status::Token, "attribute missing"))
    }
}

fn unwrap_failure(error: Error) -> Failure {
    match error {
        Error::Pkcs11(rv, _) if tampered(rv) => {
            Failure::new(Status::Integrity, "wrapped key failed authentication")
        }
        other => other.into(),
    }
}

fn tampered(rv: RvError) -> bool {
    matches!(
        rv,
        RvError::WrappedKeyInvalid
            | RvError::WrappedKeyLenRange
            | RvError::FunctionFailed
            | RvError::GeneralError
    )
}

fn key_type(alg: Alg) -> KeyType {
    match alg {
        Alg::Es256 => KeyType::EC,
        Alg::Rs256 => KeyType::RSA,
        Alg::Ed25519 => KeyType::EC_EDWARDS,
    }
}

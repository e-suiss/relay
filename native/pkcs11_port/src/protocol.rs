//! Version 1 of the request and response protocol spoken over `{:packet, 4}` frames.

use zeroize::Zeroizing;

/// Protocol version carried as the first byte of every request and response.
pub const VERSION: u8 = 1;

/// Largest frame the port accepts.
pub const MAX_FRAME: usize = 1 << 20;

/// Signature and key algorithms.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Alg {
    Es256,
    Rs256,
    Ed25519,
}

impl Alg {
    fn from_byte(byte: u8) -> Option<Self> {
        match byte {
            1 => Some(Alg::Es256),
            2 => Some(Alg::Rs256),
            3 => Some(Alg::Ed25519),
            _ => None,
        }
    }
}

/// A decoded request. Plaintext key material stays in zeroizing buffers.
#[derive(Debug, PartialEq, Eq)]
pub enum Op {
    Ping,
    Sign {
        alg: Alg,
        label: Vec<u8>,
        message: Vec<u8>,
    },
    PublicKey {
        alg: Alg,
        label: Vec<u8>,
    },
    Wrap {
        label: Vec<u8>,
        aad: Vec<u8>,
        plaintext: Zeroizing<Vec<u8>>,
    },
    Unwrap {
        label: Vec<u8>,
        aad: Vec<u8>,
        wrapped: Vec<u8>,
    },
    Hmac {
        label: Vec<u8>,
        message: Zeroizing<Vec<u8>>,
    },
    ReadSecret {
        label: Vec<u8>,
    },
}

/// Response status codes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok = 0,
    BadRequest = 1,
    UnsupportedVersion = 2,
    NotFound = 3,
    Integrity = 4,
    Token = 5,
    Internal = 6,
}

/// A request that could not be decoded, with the request id when it was readable.
#[derive(Debug, PartialEq, Eq)]
pub struct DecodeError {
    pub id: u32,
    pub status: Status,
    pub message: &'static str,
}

struct Reader<'a> {
    buf: &'a [u8],
}

impl<'a> Reader<'a> {
    fn u8(&mut self) -> Option<u8> {
        let (&first, rest) = self.buf.split_first()?;
        self.buf = rest;
        Some(first)
    }

    fn u32(&mut self) -> Option<u32> {
        if self.buf.len() < 4 {
            return None;
        }
        let (head, rest) = self.buf.split_at(4);
        self.buf = rest;
        Some(u32::from_be_bytes([head[0], head[1], head[2], head[3]]))
    }

    fn field(&mut self) -> Option<&'a [u8]> {
        let len = usize::try_from(self.u32()?).ok()?;
        if self.buf.len() < len {
            return None;
        }
        let (head, rest) = self.buf.split_at(len);
        self.buf = rest;
        Some(head)
    }

    fn alg(&mut self) -> Option<Alg> {
        Alg::from_byte(self.u8()?)
    }

    fn finished(&self) -> bool {
        self.buf.is_empty()
    }
}

/// Decodes one request frame into its id and operation.
pub fn decode(frame: &[u8]) -> Result<(u32, Op), DecodeError> {
    let mut reader = Reader { buf: frame };
    let bad = |id| DecodeError {
        id,
        status: Status::BadRequest,
        message: "malformed request",
    };

    let version = reader.u8().ok_or(bad(0))?;
    let id = reader.u32().ok_or(bad(0))?;
    if version != VERSION {
        return Err(DecodeError {
            id,
            status: Status::UnsupportedVersion,
            message: "unsupported protocol version",
        });
    }

    let op = match reader.u8().ok_or(bad(id))? {
        0 => Some(Op::Ping),
        1 => decode_sign(&mut reader),
        2 => decode_public_key(&mut reader),
        3 => decode_wrap(&mut reader),
        4 => decode_unwrap(&mut reader),
        5 => decode_hmac(&mut reader),
        6 => decode_read_secret(&mut reader),
        _ => None,
    };

    match op {
        Some(op) if reader.finished() => Ok((id, op)),
        _ => Err(bad(id)),
    }
}

fn decode_sign(reader: &mut Reader<'_>) -> Option<Op> {
    let alg = reader.alg()?;
    let label = reader.field()?.to_vec();
    let message = reader.field()?.to_vec();
    Some(Op::Sign {
        alg,
        label,
        message,
    })
}

fn decode_public_key(reader: &mut Reader<'_>) -> Option<Op> {
    let alg = reader.alg()?;
    let label = reader.field()?.to_vec();
    Some(Op::PublicKey { alg, label })
}

fn decode_wrap(reader: &mut Reader<'_>) -> Option<Op> {
    let label = reader.field()?.to_vec();
    let aad = reader.field()?.to_vec();
    let plaintext = Zeroizing::new(reader.field()?.to_vec());
    Some(Op::Wrap {
        label,
        aad,
        plaintext,
    })
}

fn decode_unwrap(reader: &mut Reader<'_>) -> Option<Op> {
    let label = reader.field()?.to_vec();
    let aad = reader.field()?.to_vec();
    let wrapped = reader.field()?.to_vec();
    Some(Op::Unwrap {
        label,
        aad,
        wrapped,
    })
}

fn decode_hmac(reader: &mut Reader<'_>) -> Option<Op> {
    let label = reader.field()?.to_vec();
    let message = Zeroizing::new(reader.field()?.to_vec());
    Some(Op::Hmac { label, message })
}

fn decode_read_secret(reader: &mut Reader<'_>) -> Option<Op> {
    let label = reader.field()?.to_vec();
    Some(Op::ReadSecret { label })
}

/// Encodes a response frame body. The buffer is zeroized when dropped.
pub fn encode(id: u32, status: Status, fields: &[&[u8]]) -> Zeroizing<Vec<u8>> {
    let size = 6 + fields.iter().map(|f| 4 + f.len()).sum::<usize>();
    let mut out = Zeroizing::new(Vec::with_capacity(size));
    out.push(VERSION);
    out.extend_from_slice(&id.to_be_bytes());
    out.push(status as u8);
    for field in fields {
        let len = u32::try_from(field.len()).unwrap_or(u32::MAX);
        out.extend_from_slice(&len.to_be_bytes());
        out.extend_from_slice(field);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn field(bytes: &[u8]) -> Vec<u8> {
        let mut out = (bytes.len() as u32).to_be_bytes().to_vec();
        out.extend_from_slice(bytes);
        out
    }

    fn request(id: u32, op: u8, body: &[u8]) -> Vec<u8> {
        let mut out = vec![VERSION];
        out.extend_from_slice(&id.to_be_bytes());
        out.push(op);
        out.extend_from_slice(body);
        out
    }

    #[test]
    fn tn_63_decodes_ping() {
        assert_eq!(decode(&request(7, 0, &[])), Ok((7, Op::Ping)));
    }

    #[test]
    fn tn_63_decodes_sign() {
        let body = [vec![1], field(b"apns"), field(b"header.claims")].concat();
        assert_eq!(
            decode(&request(9, 1, &body)),
            Ok((
                9,
                Op::Sign {
                    alg: Alg::Es256,
                    label: b"apns".to_vec(),
                    message: b"header.claims".to_vec()
                }
            ))
        );
    }

    #[test]
    fn tn_27_decodes_wrap_and_unwrap() {
        let body = [field(b"kek"), field(b"tenant"), field(&[1, 2, 3])].concat();
        let (_, op) = decode(&request(1, 3, &body)).unwrap();
        assert_eq!(
            op,
            Op::Wrap {
                label: b"kek".to_vec(),
                aad: b"tenant".to_vec(),
                plaintext: Zeroizing::new(vec![1, 2, 3])
            }
        );
        let (_, op) = decode(&request(2, 4, &body)).unwrap();
        assert!(matches!(op, Op::Unwrap { .. }));
    }

    #[test]
    fn tn_66_decodes_hmac() {
        let body = [field(b"bidx"), field(b"message")].concat();
        assert_eq!(
            decode(&request(10, 5, &body)),
            Ok((
                10,
                Op::Hmac {
                    label: b"bidx".to_vec(),
                    message: Zeroizing::new(b"message".to_vec())
                }
            ))
        );
        let body = [field(b"bidx")].concat();
        assert_eq!(
            decode(&request(11, 5, &body)).unwrap_err().status,
            Status::BadRequest
        );
    }

    #[test]
    fn tn_26_decodes_read_secret() {
        assert_eq!(
            decode(&request(12, 6, &field(b"smtp"))),
            Ok((
                12,
                Op::ReadSecret {
                    label: b"smtp".to_vec()
                }
            ))
        );
        let body = [field(b"smtp"), field(b"x")].concat();
        assert_eq!(decode(&request(13, 6, &body)).unwrap_err().id, 13);
    }

    #[test]
    fn tn_63_decodes_public_key() {
        let body = [vec![3], field(b"checkpoint")].concat();
        assert_eq!(
            decode(&request(3, 2, &body)),
            Ok((
                3,
                Op::PublicKey {
                    alg: Alg::Ed25519,
                    label: b"checkpoint".to_vec()
                }
            ))
        );
    }

    #[test]
    fn tn_63_rejects_trailing_bytes_and_truncation() {
        let body = [vec![1], field(b"apns"), field(b"m"), vec![0]].concat();
        assert_eq!(decode(&request(4, 1, &body)).unwrap_err().id, 4);
        let body = [vec![1], field(b"apns"), vec![0, 0, 0, 9, 1]].concat();
        assert_eq!(
            decode(&request(5, 1, &body)).unwrap_err().status,
            Status::BadRequest
        );
        assert_eq!(decode(&[]).unwrap_err().id, 0);
    }

    #[test]
    fn tn_63_rejects_unknown_op_alg_and_version() {
        assert_eq!(
            decode(&request(6, 9, &[])).unwrap_err().status,
            Status::BadRequest
        );
        let body = [vec![9], field(b"k")].concat();
        assert_eq!(
            decode(&request(6, 2, &body)).unwrap_err().status,
            Status::BadRequest
        );
        let mut frame = request(8, 0, &[]);
        frame[0] = 2;
        assert_eq!(
            decode(&frame),
            Err(DecodeError {
                id: 8,
                status: Status::UnsupportedVersion,
                message: "unsupported protocol version"
            })
        );
    }

    #[test]
    fn tn_63_encodes_response() {
        let out = encode(0x0102_0304, Status::Ok, &[b"ab", b""]);
        assert_eq!(
            out.as_slice(),
            &[1, 1, 2, 3, 4, 0, 0, 0, 0, 2, b'a', b'b', 0, 0, 0, 0]
        );
    }
}

//! Signature and public key encodings: DER ECDSA to fixed `R‖S`, and `CKA_EC_POINT` unwrapping.

/// Byte length of one P-256 scalar.
pub const P256_SCALAR: usize = 32;

/// Converts a DER `ECDSA-Sig-Value` into the fixed-size `R‖S` form used by JWS.
pub fn ecdsa_der_to_raw(der: &[u8], scalar: usize) -> Option<Vec<u8>> {
    let (tag, body, rest) = tlv(der)?;
    if tag != 0x30 || !rest.is_empty() {
        return None;
    }
    let (r, body) = integer(body, scalar)?;
    let (s, body) = integer(body, scalar)?;
    if !body.is_empty() {
        return None;
    }
    let mut out = vec![0u8; 2 * scalar];
    out[scalar - r.len()..scalar].copy_from_slice(r);
    out[2 * scalar - s.len()..].copy_from_slice(s);
    Some(out)
}

/// Returns an ECDSA signature as `R‖S`; PKCS#11 tokens return that form, bridges may return DER.
pub fn ecdsa_raw(signature: &[u8], scalar: usize) -> Option<Vec<u8>> {
    if signature.len() == 2 * scalar {
        Some(signature.to_vec())
    } else {
        ecdsa_der_to_raw(signature, scalar)
    }
}

/// Returns the raw point from a `CKA_EC_POINT` value, which is a DER OCTET STRING on conforming tokens.
pub fn ec_point(value: &[u8], point_len: usize) -> Option<Vec<u8>> {
    if value.len() == point_len {
        return Some(value.to_vec());
    }
    match tlv(value)? {
        (0x04, body, []) if body.len() == point_len => Some(body.to_vec()),
        _ => None,
    }
}

fn tlv(input: &[u8]) -> Option<(u8, &[u8], &[u8])> {
    let (&tag, rest) = input.split_first()?;
    let (&first, rest) = rest.split_first()?;
    let (len, rest) = match first {
        0x00..=0x7f => (usize::from(first), rest),
        0x81 => {
            let (&len, rest) = rest.split_first()?;
            if len < 0x80 {
                return None;
            }
            (usize::from(len), rest)
        }
        _ => return None,
    };
    if rest.len() < len {
        return None;
    }
    let (body, rest) = rest.split_at(len);
    Some((tag, body, rest))
}

fn integer(input: &[u8], scalar: usize) -> Option<(&[u8], &[u8])> {
    let (tag, body, rest) = tlv(input)?;
    if tag != 0x02 || body.is_empty() || body[0] & 0x80 != 0 {
        return None;
    }
    let value = match body {
        [0x00, next, ..] if next & 0x80 == 0 => return None,
        [0x00, tail @ ..] if !tail.is_empty() => tail,
        _ => body,
    };
    if value.len() > scalar || value.iter().all(|&b| b == 0) {
        return None;
    }
    Some((value, rest))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    fn der(r: &[u8], s: &[u8]) -> Vec<u8> {
        let mut body = vec![0x02, r.len() as u8];
        body.extend_from_slice(r);
        body.extend_from_slice(&[0x02, s.len() as u8]);
        body.extend_from_slice(s);
        let mut out = vec![0x30, body.len() as u8];
        out.extend_from_slice(&body);
        out
    }

    const R: &str = "efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716";
    const S: &str = "f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8";

    #[test]
    fn tn_28_rfc6979_p256_sha256_sample_vector() {
        let der = hex(&format!("3046022100{R}022100{S}"));
        assert_eq!(
            ecdsa_der_to_raw(&der, P256_SCALAR),
            Some(hex(&format!("{R}{S}")))
        );
    }

    #[test]
    fn tn_28_short_r_is_left_padded() {
        let r = hex("7fd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf37");
        let s = hex(&format!("00{S}"));
        let raw = ecdsa_der_to_raw(&der(&r, &s), P256_SCALAR).unwrap();
        assert_eq!(raw.len(), 64);
        assert_eq!(raw[0], 0);
        assert_eq!(&raw[1..32], r.as_slice());
        assert_eq!(&raw[32..], hex(S).as_slice());
    }

    #[test]
    fn tn_28_short_s_is_left_padded() {
        let r = hex(&format!("00{R}"));
        let s = hex("0001020304050607080910111213141516171819202122232425262728");
        let s = &s[1..];
        let raw = ecdsa_der_to_raw(&der(&r, s), P256_SCALAR).unwrap();
        assert_eq!(&raw[..32], hex(R).as_slice());
        assert_eq!(
            &raw[32..32 + 32 - s.len()],
            vec![0u8; 32 - s.len()].as_slice()
        );
        assert_eq!(&raw[64 - s.len()..], s);
    }

    #[test]
    fn tn_28_short_r_and_short_s() {
        let raw = ecdsa_der_to_raw(&der(&[0x01], &[0x7f]), P256_SCALAR).unwrap();
        let mut expected = vec![0u8; 64];
        expected[31] = 0x01;
        expected[63] = 0x7f;
        assert_eq!(raw, expected);
    }

    #[test]
    fn tn_28_rejects_malformed_der() {
        let r = hex(&format!("00{R}"));
        let s = hex(&format!("00{S}"));
        let good = der(&r, &s);

        let mut trailing = good.clone();
        trailing.push(0);
        assert_eq!(ecdsa_der_to_raw(&trailing, P256_SCALAR), None);

        let mut wrong_tag = good.clone();
        wrong_tag[0] = 0x31;
        assert_eq!(ecdsa_der_to_raw(&wrong_tag, P256_SCALAR), None);

        assert_eq!(ecdsa_der_to_raw(&der(&hex(R), &s), P256_SCALAR), None);
        assert_eq!(ecdsa_der_to_raw(&der(&[0x00, 0x01], &s), P256_SCALAR), None);
        assert_eq!(ecdsa_der_to_raw(&der(&[0x00], &s), P256_SCALAR), None);
        assert_eq!(ecdsa_der_to_raw(&der(&[], &s), P256_SCALAR), None);

        let mut long = vec![0x01];
        long.extend_from_slice(&hex(R));
        assert_eq!(ecdsa_der_to_raw(&der(&long, &s), P256_SCALAR), None);

        assert_eq!(ecdsa_der_to_raw(&good[..good.len() - 1], P256_SCALAR), None);
        assert_eq!(ecdsa_der_to_raw(&[], P256_SCALAR), None);
    }

    #[test]
    fn tn_28_raw_signature_passes_through() {
        let raw = hex(&format!("{R}{S}"));
        assert_eq!(ecdsa_raw(&raw, P256_SCALAR), Some(raw));
        let der = hex(&format!("3046022100{R}022100{S}"));
        assert_eq!(ecdsa_raw(&der, P256_SCALAR), Some(hex(&format!("{R}{S}"))));
    }

    #[test]
    fn tn_31_ec_point_is_unwrapped_from_octet_string() {
        let mut point = vec![0x04];
        point.extend_from_slice(&hex(R));
        point.extend_from_slice(&hex(S));
        let mut wrapped = vec![0x04, 0x41];
        wrapped.extend_from_slice(&point);
        assert_eq!(ec_point(&wrapped, 65), Some(point.clone()));
        assert_eq!(ec_point(&point, 65), Some(point.clone()));
        assert_eq!(ec_point(&wrapped[..66], 65), None);
        let mut ed = vec![0x04, 0x20];
        ed.extend_from_slice(&hex(R));
        assert_eq!(ec_point(&ed, 32), Some(hex(R)));
    }
}

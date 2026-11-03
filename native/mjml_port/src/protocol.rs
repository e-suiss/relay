//! Version 1 of the request and response protocol spoken over one `{:packet, 4}` frame each way.

use crate::compile::{Failure, Kind, MAX_INPUT};

/// Protocol version carried as the first byte of every request and response.
pub const VERSION: u8 = 1;

/// Largest request frame the program reads.
pub const MAX_FRAME: usize = MAX_INPUT + 64;

/// A decoded compile request.
#[derive(Debug, PartialEq, Eq)]
pub struct Request<'a> {
    pub deadline_ms: u32,
    pub max_output: u32,
    pub source: &'a [u8],
}

/// Response status codes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok = 0,
    BadRequest = 1,
    UnsupportedVersion = 2,
    InputTooLarge = 3,
    OutputTooLarge = 4,
    Encoding = 5,
    Include = 6,
    Parse = 7,
    Render = 8,
}

impl From<Kind> for Status {
    fn from(kind: Kind) -> Self {
        match kind {
            Kind::InputTooLarge => Status::InputTooLarge,
            Kind::OutputTooLarge => Status::OutputTooLarge,
            Kind::Encoding => Status::Encoding,
            Kind::Include => Status::Include,
            Kind::Parse => Status::Parse,
            Kind::Render => Status::Render,
        }
    }
}

/// A request that could not be decoded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecodeError {
    pub status: Status,
    pub message: &'static str,
}

fn u32_at(buf: &[u8], at: usize) -> Option<u32> {
    let bytes = buf.get(at..at + 4)?;
    Some(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

/// Decodes a request frame: version, deadline in milliseconds, output limit in bytes, length-prefixed MJML source.
pub fn decode(frame: &[u8]) -> Result<Request<'_>, DecodeError> {
    let bad = DecodeError {
        status: Status::BadRequest,
        message: "malformed request",
    };
    let (&version, _) = frame.split_first().ok_or(bad)?;
    if version != VERSION {
        return Err(DecodeError {
            status: Status::UnsupportedVersion,
            message: "unsupported protocol version",
        });
    }
    let deadline_ms = u32_at(frame, 1).ok_or(bad)?;
    let max_output = u32_at(frame, 5).ok_or(bad)?;
    let len = usize::try_from(u32_at(frame, 9).ok_or(bad)?).map_err(|_| bad)?;
    let source = frame.get(13..).ok_or(bad)?;
    if source.len() != len || deadline_ms == 0 || max_output == 0 {
        return Err(bad);
    }
    Ok(Request {
        deadline_ms,
        max_output,
        source,
    })
}

/// Encodes a successful response carrying the compiled HTML.
pub fn encode_ok(html: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(10 + html.len());
    out.push(VERSION);
    out.push(Status::Ok as u8);
    push_field(&mut out, html);
    out
}

/// Encodes a failure response: status, line, column and message.
pub fn encode_failure(status: Status, line: u32, column: u32, message: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(14 + message.len());
    out.push(VERSION);
    out.push(status as u8);
    out.extend_from_slice(&line.to_be_bytes());
    out.extend_from_slice(&column.to_be_bytes());
    push_field(&mut out, message.as_bytes());
    out
}

/// Encodes a compilation failure.
pub fn encode_compile_failure(failure: &Failure) -> Vec<u8> {
    encode_failure(
        failure.kind.into(),
        failure.line,
        failure.column,
        &failure.message,
    )
}

fn push_field(out: &mut Vec<u8>, field: &[u8]) {
    let len = u32::try_from(field.len()).unwrap_or(u32::MAX);
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(field);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(version: u8, deadline: u32, max_output: u32, source: &[u8]) -> Vec<u8> {
        let mut out = vec![version];
        out.extend_from_slice(&deadline.to_be_bytes());
        out.extend_from_slice(&max_output.to_be_bytes());
        out.extend_from_slice(&(source.len() as u32).to_be_bytes());
        out.extend_from_slice(source);
        out
    }

    #[test]
    fn t_98_decodes_request() {
        assert_eq!(
            decode(&request(1, 2000, 4096, b"<mjml />")),
            Ok(Request {
                deadline_ms: 2000,
                max_output: 4096,
                source: b"<mjml />"
            })
        );
        assert!(decode(&request(1, 1, 1, b"")).is_ok());
    }

    #[test]
    fn t_98_rejects_malformed_requests() {
        let mut trailing = request(1, 10, 10, b"ab");
        trailing.push(0);
        let mut truncated = request(1, 10, 10, b"ab");
        truncated.pop();
        for frame in [
            vec![],
            vec![1, 0, 0],
            trailing,
            truncated,
            request(1, 0, 10, b"a"),
            request(1, 10, 0, b"a"),
        ] {
            assert_eq!(decode(&frame).unwrap_err().status, Status::BadRequest);
        }
        assert_eq!(
            decode(&request(2, 10, 10, b"a")).unwrap_err().status,
            Status::UnsupportedVersion
        );
    }

    #[test]
    fn t_98_encodes_responses() {
        assert_eq!(encode_ok(b"ab"), [1, 0, 0, 0, 0, 2, b'a', b'b']);
        assert_eq!(
            encode_failure(Status::Parse, 2, 7, "x"),
            [1, 7, 0, 0, 0, 2, 0, 0, 0, 7, 0, 0, 0, 1, b'x']
        );
        let failure = Failure {
            kind: Kind::Include,
            message: String::new(),
            line: 1,
            column: 1,
        };
        assert_eq!(encode_compile_failure(&failure)[1], Status::Include as u8);
    }
}

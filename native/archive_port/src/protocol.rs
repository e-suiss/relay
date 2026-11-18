//! Version 1 of the request and response protocol spoken over `{:packet, 4}` frames, one response per request.

/// Protocol version carried as the first byte of every request and response.
pub const VERSION: u8 = 1;

/// Largest request frame the program reads.
pub const MAX_FRAME: usize = 256 * 1024 * 1024;

/// Most columns a table may have.
pub const MAX_COLUMNS: usize = 1600;

const OP_OPEN: u8 = 1;
const OP_ROWS: u8 = 2;
const OP_CLOSE: u8 = 3;
const OP_VERIFY: u8 = 4;
const OP_READ_OPEN: u8 = 5;
const OP_READ_NEXT: u8 = 6;

/// Response status codes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Ok = 0,
    BadRequest = 1,
    UnsupportedVersion = 2,
    TooLarge = 3,
    OutOfOrder = 4,
    Io = 5,
    Parquet = 6,
    Encoding = 7,
}

/// A decoded request.
#[derive(Debug, PartialEq, Eq)]
pub enum Request<'a> {
    Open { path: &'a str, columns: Vec<String> },
    Rows { count: u32, body: &'a [u8] },
    Close,
    Verify { path: &'a str },
    ReadOpen { path: &'a str },
    ReadNext { max_rows: u32 },
}

/// One row of a `Rows` request: its canonical encoding and its column values.
#[derive(Debug, PartialEq, Eq)]
pub struct RawRow<'a> {
    pub raw: &'a [u8],
    pub values: Vec<Option<&'a [u8]>>,
}

/// A request that could not be decoded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecodeError {
    pub status: Status,
    pub message: &'static str,
}

const BAD: DecodeError = DecodeError {
    status: Status::BadRequest,
    message: "malformed request",
};

struct Cursor<'a> {
    buf: &'a [u8],
    at: usize,
}

impl<'a> Cursor<'a> {
    fn take(&mut self, len: usize) -> Result<&'a [u8], DecodeError> {
        let end = self.at.checked_add(len).ok_or(BAD)?;
        let bytes = self.buf.get(self.at..end).ok_or(BAD)?;
        self.at = end;
        Ok(bytes)
    }

    fn u8(&mut self) -> Result<u8, DecodeError> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<usize, DecodeError> {
        let bytes = self.take(2)?;
        Ok(usize::from(u16::from_be_bytes([bytes[0], bytes[1]])))
    }

    fn u32(&mut self) -> Result<u32, DecodeError> {
        let bytes = self.take(4)?;
        Ok(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }

    fn len32(&mut self) -> Result<usize, DecodeError> {
        usize::try_from(self.u32()?).map_err(|_| BAD)
    }

    fn text(&mut self, len: usize) -> Result<&'a str, DecodeError> {
        std::str::from_utf8(self.take(len)?).map_err(|_| BAD)
    }

    fn rest(&mut self) -> &'a [u8] {
        let rest = &self.buf[self.at..];
        self.at = self.buf.len();
        rest
    }

    fn done(&self) -> Result<(), DecodeError> {
        if self.at == self.buf.len() {
            Ok(())
        } else {
            Err(BAD)
        }
    }
}

/// Decodes a request frame: version, operation, then the operation's body.
pub fn decode(frame: &[u8]) -> Result<Request<'_>, DecodeError> {
    let mut cursor = Cursor { buf: frame, at: 0 };
    if cursor.u8()? != VERSION {
        return Err(DecodeError {
            status: Status::UnsupportedVersion,
            message: "unsupported protocol version",
        });
    }
    let request = match cursor.u8()? {
        OP_OPEN => {
            let len = cursor.len32()?;
            let path = cursor.text(len)?;
            let count = cursor.u16()?;
            if count == 0 || count > MAX_COLUMNS {
                return Err(BAD);
            }
            let mut columns = Vec::with_capacity(count);
            for _ in 0..count {
                let len = cursor.u16()?;
                let name = cursor.text(len)?;
                if name.is_empty() {
                    return Err(BAD);
                }
                columns.push(name.to_owned());
            }
            Request::Open { path, columns }
        }
        OP_ROWS => {
            let count = cursor.u32()?;
            Request::Rows {
                count,
                body: cursor.rest(),
            }
        }
        OP_CLOSE => Request::Close,
        OP_VERIFY => {
            let len = cursor.len32()?;
            Request::Verify {
                path: cursor.text(len)?,
            }
        }
        OP_READ_OPEN => {
            let len = cursor.len32()?;
            Request::ReadOpen {
                path: cursor.text(len)?,
            }
        }
        OP_READ_NEXT => Request::ReadNext {
            max_rows: cursor.u32()?,
        },
        _ => return Err(BAD),
    };
    cursor.done()?;
    Ok(request)
}

/// Splits the body of a `Rows` request into `count` rows of `columns` values each; every value is `0` for null or `1`, a four-byte length and the bytes.
pub fn split_rows(body: &[u8], count: u32, columns: usize) -> Result<Vec<RawRow<'_>>, DecodeError> {
    let mut cursor = Cursor { buf: body, at: 0 };
    let mut rows = Vec::new();
    for _ in 0..count {
        let start = cursor.at;
        let mut values = Vec::with_capacity(columns);
        for _ in 0..columns {
            match cursor.u8()? {
                0 => values.push(None),
                1 => {
                    let len = cursor.len32()?;
                    values.push(Some(cursor.take(len)?));
                }
                _ => return Err(BAD),
            }
        }
        rows.push(RawRow {
            raw: &body[start..cursor.at],
            values,
        });
    }
    cursor.done()?;
    Ok(rows)
}

/// Encodes an empty successful response.
pub fn encode_ok() -> Vec<u8> {
    vec![VERSION, Status::Ok as u8]
}

/// Encodes a successful response carrying a row count, a digest and a file size.
pub fn encode_summary(rows: u64, digest: &[u8; 32], bytes: u64) -> Vec<u8> {
    let mut out = Vec::with_capacity(50);
    out.push(VERSION);
    out.push(Status::Ok as u8);
    out.extend_from_slice(&rows.to_be_bytes());
    out.extend_from_slice(digest);
    out.extend_from_slice(&bytes.to_be_bytes());
    out
}

/// Encodes a successful verification: the summary followed by the column names of the file.
pub fn encode_verified(rows: u64, digest: &[u8; 32], bytes: u64, columns: &[String]) -> Vec<u8> {
    let mut out = encode_summary(rows, digest, bytes);
    push_columns(&mut out, columns);
    out
}

/// Encodes the column names of a file opened for reading.
pub fn encode_columns(columns: &[String]) -> Vec<u8> {
    let mut out = encode_ok();
    push_columns(&mut out, columns);
    out
}

/// Encodes a batch of rows read back: their count and their canonical encoding.
pub fn encode_rows(count: u32, rows: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(6 + rows.len());
    out.push(VERSION);
    out.push(Status::Ok as u8);
    out.extend_from_slice(&count.to_be_bytes());
    out.extend_from_slice(rows);
    out
}

fn push_columns(out: &mut Vec<u8>, columns: &[String]) {
    let count = u16::try_from(columns.len()).unwrap_or(u16::MAX);
    out.extend_from_slice(&count.to_be_bytes());
    for name in columns.iter().take(usize::from(count)) {
        let len = u16::try_from(name.len()).unwrap_or(u16::MAX);
        out.extend_from_slice(&len.to_be_bytes());
        out.extend_from_slice(&name.as_bytes()[..usize::from(len)]);
    }
}

/// Encodes a failure response: status and message.
pub fn encode_failure(status: Status, message: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(6 + message.len());
    out.push(VERSION);
    out.push(status as u8);
    let len = u32::try_from(message.len()).unwrap_or(u32::MAX);
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(message.as_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open(path: &str, columns: &[&str]) -> Vec<u8> {
        let mut out = vec![VERSION, OP_OPEN];
        out.extend_from_slice(&(path.len() as u32).to_be_bytes());
        out.extend_from_slice(path.as_bytes());
        out.extend_from_slice(&(columns.len() as u16).to_be_bytes());
        for name in columns {
            out.extend_from_slice(&(name.len() as u16).to_be_bytes());
            out.extend_from_slice(name.as_bytes());
        }
        out
    }

    #[test]
    fn op_84_decodes_requests() {
        assert_eq!(
            decode(&open("/tmp/a.parquet", &["id", "name"])),
            Ok(Request::Open {
                path: "/tmp/a.parquet",
                columns: vec!["id".to_owned(), "name".to_owned()],
            })
        );
        assert_eq!(
            decode(&[VERSION, OP_ROWS, 0, 0, 0, 2, 9, 9]),
            Ok(Request::Rows {
                count: 2,
                body: &[9, 9],
            })
        );
        assert_eq!(decode(&[VERSION, OP_CLOSE]), Ok(Request::Close));
        assert_eq!(
            decode(&[VERSION, OP_VERIFY, 0, 0, 0, 2, b'/', b'a']),
            Ok(Request::Verify { path: "/a" })
        );
        assert_eq!(
            decode(&[VERSION, OP_READ_OPEN, 0, 0, 0, 2, b'/', b'a']),
            Ok(Request::ReadOpen { path: "/a" })
        );
        assert_eq!(
            decode(&[VERSION, OP_READ_NEXT, 0, 0, 1, 0]),
            Ok(Request::ReadNext { max_rows: 256 })
        );
    }

    #[test]
    fn op_84_rejects_malformed_requests() {
        let mut trailing = open("/a", &["id"]);
        trailing.push(0);
        let mut truncated = open("/a", &["id"]);
        truncated.pop();
        for frame in [
            vec![],
            vec![VERSION],
            vec![VERSION, 9],
            vec![VERSION, OP_CLOSE, 0],
            trailing,
            truncated,
            open("/a", &[]),
            open("/a", &[""]),
            vec![VERSION, OP_VERIFY, 0, 0, 0, 1, 0xff],
        ] {
            assert_eq!(decode(&frame).unwrap_err().status, Status::BadRequest);
        }
        assert_eq!(
            decode(&[2, OP_CLOSE]).unwrap_err().status,
            Status::UnsupportedVersion
        );
    }

    #[test]
    fn op_84_splits_rows_into_their_canonical_encoding() {
        let body = [1, 0, 0, 0, 1, b'1', 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, b'x'];
        let rows = split_rows(&body, 2, 2).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].raw, &body[..7]);
        assert_eq!(rows[0].values, [Some(&b"1"[..]), None]);
        assert_eq!(rows[1].values, [Some(&b""[..]), Some(&b"x"[..])]);
        assert!(split_rows(&body, 3, 2).is_err());
        assert!(split_rows(&body, 1, 2).is_err());
        assert!(split_rows(&[2], 1, 1).is_err());
        assert!(split_rows(&[1, 0, 0, 0, 9, b'a'], 1, 1).is_err());
        assert!(split_rows(&[], 0, 3).unwrap().is_empty());
    }

    #[test]
    fn op_84_encodes_responses() {
        assert_eq!(encode_ok(), [VERSION, 0]);
        let summary = encode_summary(3, &[7; 32], 9);
        assert_eq!(summary.len(), 50);
        assert_eq!(&summary[2..10], &3u64.to_be_bytes());
        assert_eq!(&summary[10..42], &[7; 32]);
        assert_eq!(&summary[42..50], &9u64.to_be_bytes());
        let verified = encode_verified(0, &[0; 32], 0, &["id".to_owned()]);
        assert_eq!(&verified[50..], &[0, 1, 0, 2, b'i', b'd']);
        assert_eq!(
            encode_columns(&["id".to_owned()]),
            [VERSION, 0, 0, 1, 0, 2, b'i', b'd']
        );
        assert_eq!(encode_rows(1, &[0]), [VERSION, 0, 0, 0, 0, 1, 0]);
        assert_eq!(
            encode_failure(Status::Io, "x"),
            [VERSION, Status::Io as u8, 0, 0, 0, 1, b'x']
        );
    }
}

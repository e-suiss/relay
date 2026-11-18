//! Relay's cold archive Port program: reads `{:packet, 4}` request frames on stdin and answers each with one frame on stdout until stdin closes. A session opens a Parquet file, receives rows in batches and closes it with its row count and digest; a verification reads a file back and returns the same summary.

mod archive;
mod protocol;

use std::io::{ErrorKind, Read, Write};
use std::path::Path;
use std::process::ExitCode;

use protocol::{Request, Status};

const EXIT_USAGE: u8 = 2;
const EXIT_IO: u8 = 4;
const READ_BYTES: usize = 16 * 1024 * 1024;

enum Frame {
    Body(Vec<u8>),
    TooLarge(usize),
}

#[derive(Default)]
struct Session {
    writer: Option<archive::Writer>,
    reader: Option<archive::Reader>,
}

fn main() -> ExitCode {
    if std::env::args().len() > 1 {
        eprintln!("archive_port: takes no arguments");
        return ExitCode::from(EXIT_USAGE);
    }
    let mut input = std::io::stdin().lock();
    let mut output = std::io::stdout().lock();
    let mut session = Session::default();
    loop {
        let response = match read_frame(&mut input) {
            Ok(Some(Frame::Body(frame))) => session.handle(&frame),
            Ok(Some(Frame::TooLarge(len))) => {
                if skip(&mut input, len).is_err() {
                    return ExitCode::from(EXIT_IO);
                }
                session.reset();
                protocol::encode_failure(Status::TooLarge, "request frame is too large")
            }
            Ok(None) => return ExitCode::SUCCESS,
            Err(_) => return ExitCode::from(EXIT_IO),
        };
        if write_frame(&mut output, &response).is_err() {
            return ExitCode::from(EXIT_IO);
        }
    }
}

impl Session {
    fn reset(&mut self) {
        self.writer = None;
        self.reader = None;
    }

    fn busy(&self) -> bool {
        self.writer.is_some() || self.reader.is_some()
    }

    fn handle(&mut self, frame: &[u8]) -> Vec<u8> {
        match protocol::decode(frame) {
            Ok(request) => self.apply(request),
            Err(error) => {
                self.reset();
                protocol::encode_failure(error.status, error.message)
            }
        }
    }

    fn apply(&mut self, request: Request<'_>) -> Vec<u8> {
        match request {
            Request::Open { path, columns } => {
                if self.busy() {
                    self.reset();
                    return out_of_order();
                }
                let path = match absolute(path) {
                    Ok(path) => path,
                    Err(response) => return response,
                };
                match archive::Writer::create(path, &columns) {
                    Ok(writer) => {
                        self.writer = Some(writer);
                        protocol::encode_ok()
                    }
                    Err(error) => failure(&error),
                }
            }
            Request::Rows { count, body } => {
                let Some(writer) = self.writer.as_mut() else {
                    return out_of_order();
                };
                let result = protocol::split_rows(body, count, writer.columns())
                    .map_err(|error| protocol::encode_failure(error.status, error.message))
                    .and_then(|rows| {
                        rows.iter()
                            .try_for_each(|row| writer.push(row.raw, &row.values))
                            .map_err(|error| failure(&error))
                    });
                match result {
                    Ok(()) => protocol::encode_ok(),
                    Err(response) => {
                        self.writer = None;
                        response
                    }
                }
            }
            Request::Close => match self.writer.take() {
                Some(writer) => match writer.finish() {
                    Ok(summary) => {
                        protocol::encode_summary(summary.rows, &summary.digest, summary.bytes)
                    }
                    Err(error) => failure(&error),
                },
                None => out_of_order(),
            },
            Request::Verify { path } => {
                if self.busy() {
                    self.reset();
                    return out_of_order();
                }
                let path = match absolute(path) {
                    Ok(path) => path,
                    Err(response) => return response,
                };
                match archive::verify(path) {
                    Ok((summary, columns)) => protocol::encode_verified(
                        summary.rows,
                        &summary.digest,
                        summary.bytes,
                        &columns,
                    ),
                    Err(error) => failure(&error),
                }
            }
            Request::ReadOpen { path } => {
                if self.busy() {
                    self.reset();
                    return out_of_order();
                }
                let path = match absolute(path) {
                    Ok(path) => path,
                    Err(response) => return response,
                };
                match archive::Reader::open(path) {
                    Ok((reader, columns)) => {
                        self.reader = Some(reader);
                        protocol::encode_columns(&columns)
                    }
                    Err(error) => failure(&error),
                }
            }
            Request::ReadNext { max_rows } => {
                let Some(reader) = self.reader.as_mut() else {
                    return out_of_order();
                };
                let max_rows = usize::try_from(max_rows).unwrap_or(usize::MAX);
                match reader.next_batch(max_rows, READ_BYTES) {
                    Ok((0, _)) => {
                        self.reader = None;
                        protocol::encode_rows(0, &[])
                    }
                    Ok((count, rows)) => protocol::encode_rows(count, &rows),
                    Err(error) => {
                        self.reader = None;
                        failure(&error)
                    }
                }
            }
        }
    }
}

fn absolute(path: &str) -> Result<&Path, Vec<u8>> {
    let path = Path::new(path);
    if path.is_absolute() {
        Ok(path)
    } else {
        Err(protocol::encode_failure(Status::BadRequest, "path is not absolute"))
    }
}

fn out_of_order() -> Vec<u8> {
    protocol::encode_failure(Status::OutOfOrder, "request out of order")
}

fn failure(error: &archive::Error) -> Vec<u8> {
    let status = match error {
        archive::Error::Io(_) => Status::Io,
        archive::Error::Parquet(_) | archive::Error::Shape(_) => Status::Parquet,
        archive::Error::Encoding => Status::Encoding,
    };
    protocol::encode_failure(status, &error.to_string())
}

fn read_frame(input: &mut impl Read) -> std::io::Result<Option<Frame>> {
    let mut header = [0u8; 4];
    match input.read_exact(&mut header) {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }
    let len = usize::try_from(u32::from_be_bytes(header)).map_err(|_| ErrorKind::InvalidData)?;
    if len > protocol::MAX_FRAME {
        return Ok(Some(Frame::TooLarge(len)));
    }
    let mut frame = vec![0u8; len];
    input.read_exact(&mut frame)?;
    Ok(Some(Frame::Body(frame)))
}

fn skip(input: &mut impl Read, len: usize) -> std::io::Result<()> {
    let len = u64::try_from(len).map_err(|_| ErrorKind::InvalidData)?;
    let skipped = std::io::copy(&mut input.take(len), &mut std::io::sink())?;
    if skipped == len {
        Ok(())
    } else {
        Err(ErrorKind::UnexpectedEof.into())
    }
}

fn write_frame(output: &mut impl Write, body: &[u8]) -> std::io::Result<()> {
    let len = u32::try_from(body.len()).map_err(|_| ErrorKind::InvalidData)?;
    output.write_all(&len.to_be_bytes())?;
    output.write_all(body)?;
    output.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::archive::tests::{encode, scratch};

    fn open(path: &str, columns: &[&str]) -> Vec<u8> {
        let mut out = vec![protocol::VERSION, 1];
        out.extend_from_slice(&(path.len() as u32).to_be_bytes());
        out.extend_from_slice(path.as_bytes());
        out.extend_from_slice(&(columns.len() as u16).to_be_bytes());
        for name in columns {
            out.extend_from_slice(&(name.len() as u16).to_be_bytes());
            out.extend_from_slice(name.as_bytes());
        }
        out
    }

    fn rows(rows: &[&[Option<&str>]]) -> Vec<u8> {
        let mut out = vec![protocol::VERSION, 2];
        out.extend_from_slice(&(rows.len() as u32).to_be_bytes());
        for row in rows {
            out.extend_from_slice(&encode(row));
        }
        out
    }

    fn verify(path: &str) -> Vec<u8> {
        let mut out = vec![protocol::VERSION, 4];
        out.extend_from_slice(&(path.len() as u32).to_be_bytes());
        out.extend_from_slice(path.as_bytes());
        out
    }

    const CLOSE: [u8; 2] = [protocol::VERSION, 3];

    fn read_next(max_rows: u32) -> Vec<u8> {
        let mut out = vec![protocol::VERSION, 6];
        out.extend_from_slice(&max_rows.to_be_bytes());
        out
    }

    #[test]
    fn op_84_frames_round_trip_and_eof_ends_cleanly() {
        let mut buf = Vec::new();
        write_frame(&mut buf, b"abc").unwrap();
        assert_eq!(buf, [0, 0, 0, 3, b'a', b'b', b'c']);
        let mut reader = buf.as_slice();
        assert!(matches!(read_frame(&mut reader), Ok(Some(Frame::Body(body))) if body == b"abc"));
        assert!(read_frame(&mut reader).unwrap().is_none());
        let mut oversized: &[u8] = &[0xff, 0xff, 0xff, 0xff];
        assert!(matches!(read_frame(&mut oversized), Ok(Some(Frame::TooLarge(_)))));
        let mut truncated: &[u8] = &[0, 0, 0, 9, 1];
        assert!(read_frame(&mut truncated).is_err());
        let mut short: &[u8] = &[1, 2];
        assert!(skip(&mut short, 3).is_err());
    }

    #[test]
    fn op_84_a_session_writes_and_verifies_a_file() {
        let path = scratch("session.parquet");
        let path = path.to_str().unwrap();
        let mut session = Session::default();
        assert_eq!(session.handle(&open(path, &["id", "name"])), [1, 0]);
        let batch = rows(&[&[Some("1"), Some("alpha")], &[Some("2"), None]]);
        assert_eq!(session.handle(&batch), [1, 0]);
        assert_eq!(session.handle(&rows(&[&[Some("3"), Some("")]])), [1, 0]);
        let closed = session.handle(&CLOSE);
        assert_eq!(&closed[..2], &[1, 0]);
        assert_eq!(&closed[2..10], &3u64.to_be_bytes());
        let verified = session.handle(&verify(path));
        assert_eq!(&verified[..50], &closed[..]);
        assert_eq!(&verified[50..], &[0, 2, 0, 2, b'i', b'd', 0, 4, b'n', b'a', b'm', b'e']);
    }

    #[test]
    fn op_84_a_file_is_read_back_in_batches_of_canonical_rows() {
        let path = scratch("read.parquet");
        let path = path.to_str().unwrap();
        let mut session = Session::default();
        assert_eq!(session.handle(&open(path, &["id", "name"])), [1, 0]);
        let all: [&[Option<&str>]; 3] = [
            &[Some("1"), Some("alpha")],
            &[Some("2"), None],
            &[Some("3"), Some("")],
        ];
        assert_eq!(session.handle(&rows(&all)), [1, 0]);
        assert_eq!(session.handle(&CLOSE)[1], 0);
        let mut opened = verify(path);
        opened[1] = 5;
        assert_eq!(
            session.handle(&opened),
            [1, 0, 0, 2, 0, 2, b'i', b'd', 0, 4, b'n', b'a', b'm', b'e']
        );
        let first = session.handle(&read_next(2));
        assert_eq!(&first[..6], &[1, 0, 0, 0, 0, 2]);
        let mut expected = encode(all[0]);
        expected.extend_from_slice(&encode(all[1]));
        assert_eq!(&first[6..], &expected[..]);
        let second = session.handle(&read_next(2));
        assert_eq!(&second[..6], &[1, 0, 0, 0, 0, 1]);
        assert_eq!(&second[6..], &encode(all[2])[..]);
        assert_eq!(session.handle(&read_next(2)), [1, 0, 0, 0, 0, 0]);
        assert_eq!(session.handle(&read_next(2))[1], Status::OutOfOrder as u8);
    }

    #[test]
    fn op_84_requests_out_of_order_are_refused() {
        let mut session = Session::default();
        assert_eq!(session.handle(&CLOSE)[1], Status::OutOfOrder as u8);
        assert_eq!(session.handle(&rows(&[]))[1], Status::OutOfOrder as u8);
        let path = scratch("order.parquet");
        let path = path.to_str().unwrap();
        assert_eq!(session.handle(&open(path, &["id"])), [1, 0]);
        assert_eq!(session.handle(&verify(path))[1], Status::OutOfOrder as u8);
        assert_eq!(session.handle(&rows(&[]))[1], Status::OutOfOrder as u8);
    }

    #[test]
    fn op_84_bad_rows_end_the_session() {
        let path = scratch("bad.parquet");
        let path = path.to_str().unwrap();
        let mut session = Session::default();
        assert_eq!(session.handle(&open(path, &["id", "name"])), [1, 0]);
        let narrow = rows(&[&[Some("1")]]);
        assert_eq!(session.handle(&narrow)[1], Status::BadRequest as u8);
        assert_eq!(session.handle(&CLOSE)[1], Status::OutOfOrder as u8);
        let other = scratch("other.parquet");
        let other = other.to_str().unwrap();
        assert_eq!(session.handle(&open(other, &["id"])), [1, 0]);
        let mut invalid = vec![protocol::VERSION, 2, 0, 0, 0, 1, 1, 0, 0, 0, 1, 0xff];
        assert_eq!(session.handle(&invalid)[1], Status::Encoding as u8);
        invalid[1] = 9;
        assert_eq!(session.handle(&invalid)[1], Status::BadRequest as u8);
    }

    #[test]
    fn op_84_paths_must_be_absolute_and_new() {
        let mut session = Session::default();
        let relative = session.handle(&open("relative.parquet", &["id"]));
        assert_eq!(relative[1], Status::BadRequest as u8);
        assert_eq!(session.handle(&verify("relative.parquet"))[1], Status::BadRequest as u8);
        let path = scratch("twice.parquet");
        let path = path.to_str().unwrap();
        assert_eq!(session.handle(&open(path, &["id"])), [1, 0]);
        assert_eq!(session.handle(&CLOSE)[1], Status::Ok as u8);
        assert_eq!(session.handle(&open(path, &["id"]))[1], Status::Io as u8);
        let missing = scratch("missing.parquet");
        let missing = missing.to_str().unwrap();
        assert_eq!(session.handle(&verify(missing))[1], Status::Io as u8);
    }
}

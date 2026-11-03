//! Relay's MJML Port program: reads one `{:packet, 4}` request frame on stdin, writes one response frame on stdout and exits; a watchdog ends the process when the request's deadline passes.

mod compile;
mod protocol;

use std::io::{ErrorKind, Read, Write};
use std::process::ExitCode;
use std::time::Duration;

use protocol::Status;

const EXIT_USAGE: u8 = 2;
const EXIT_IO: u8 = 4;
const EXIT_DEADLINE: i32 = 5;

enum Frame {
    Body(Vec<u8>),
    TooLarge,
}

fn main() -> ExitCode {
    if std::env::args().len() > 1 {
        eprintln!("mjml_port: takes no arguments");
        return ExitCode::from(EXIT_USAGE);
    }
    let response = match read_frame(&mut std::io::stdin().lock()) {
        Ok(Some(Frame::Body(frame))) => handle(&frame),
        Ok(Some(Frame::TooLarge)) => {
            protocol::encode_failure(Status::InputTooLarge, 0, 0, "request frame is too large")
        }
        Ok(None) => return ExitCode::SUCCESS,
        Err(_) => return ExitCode::from(EXIT_IO),
    };
    match write_frame(&mut std::io::stdout().lock(), &response) {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => ExitCode::from(EXIT_IO),
    }
}

fn handle(frame: &[u8]) -> Vec<u8> {
    let request = match protocol::decode(frame) {
        Ok(request) => request,
        Err(error) => return protocol::encode_failure(error.status, 0, 0, error.message),
    };
    start_watchdog(request.deadline_ms);
    let max_output = usize::try_from(request.max_output).unwrap_or(usize::MAX);
    match compile::compile(request.source, max_output) {
        Ok(html) => protocol::encode_ok(html.as_bytes()),
        Err(failure) => protocol::encode_compile_failure(&failure),
    }
}

fn start_watchdog(deadline_ms: u32) {
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(u64::from(deadline_ms)));
        std::process::exit(EXIT_DEADLINE);
    });
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
        return Ok(Some(Frame::TooLarge));
    }
    let mut frame = vec![0u8; len];
    input.read_exact(&mut frame)?;
    Ok(Some(Frame::Body(frame)))
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

    fn request(source: &[u8], max_output: u32) -> Vec<u8> {
        let mut out = vec![protocol::VERSION];
        out.extend_from_slice(&u32::MAX.to_be_bytes());
        out.extend_from_slice(&max_output.to_be_bytes());
        out.extend_from_slice(&(source.len() as u32).to_be_bytes());
        out.extend_from_slice(source);
        out
    }

    #[test]
    fn t_98_frames_round_trip_and_eof_ends_cleanly() {
        let mut buf = Vec::new();
        write_frame(&mut buf, b"abc").unwrap();
        assert_eq!(buf, [0, 0, 0, 3, b'a', b'b', b'c']);
        let mut reader = buf.as_slice();
        assert!(matches!(read_frame(&mut reader), Ok(Some(Frame::Body(body))) if body == b"abc"));
        assert!(read_frame(&mut reader).unwrap().is_none());
        let mut oversized: &[u8] = &[0xff, 0xff, 0xff, 0xff];
        assert!(matches!(
            read_frame(&mut oversized),
            Ok(Some(Frame::TooLarge))
        ));
        let mut truncated: &[u8] = &[0, 0, 0, 9, 1];
        assert!(read_frame(&mut truncated).is_err());
    }

    #[test]
    fn t_98_handles_a_compile_request() {
        let ok = handle(&request(b"<mjml><mj-body /></mjml>", 1 << 20));
        assert_eq!(&ok[..2], &[protocol::VERSION, Status::Ok as u8]);
        let include = handle(&request(
            b"<mjml><mj-body><mj-include path=\"a\" /></mj-body></mjml>",
            1 << 20,
        ));
        assert_eq!(include[1], Status::Include as u8);
        let bad = handle(&[protocol::VERSION]);
        assert_eq!(bad[1], Status::BadRequest as u8);
    }
}

//! Relay's PKCS#11 Port program: reads `{:packet, 4}` request frames on stdin and writes response frames on stdout.

mod der;
mod hsm;
mod protocol;

use std::fs::File;
use std::io::{ErrorKind, Read, Write};
use std::mem::ManuallyDrop;
use std::os::fd::FromRawFd;
use std::process::ExitCode;

use cryptoki::types::AuthPin;
use zeroize::Zeroizing;

use hsm::{Failure, Hsm};
use protocol::{Op, Status};

const EXIT_USAGE: u8 = 2;
const EXIT_TOKEN: u8 = 3;
const EXIT_IO: u8 = 4;

struct Config {
    module: String,
    token: String,
    pin_file: String,
}

fn parse_args(mut args: impl Iterator<Item = String>) -> Option<Config> {
    let (mut module, mut token, mut pin_file) = (None, None, None);
    while let Some(flag) = args.next() {
        let value = args.next()?;
        let slot = match flag.as_str() {
            "--module" => &mut module,
            "--token" => &mut token,
            "--pin-file" => &mut pin_file,
            _ => return None,
        };
        if slot.replace(value).is_some() {
            return None;
        }
    }
    Some(Config {
        module: module?,
        token: token?,
        pin_file: pin_file?,
    })
}

fn read_pin(path: &str) -> Option<AuthPin> {
    let mut raw = Zeroizing::new(Vec::new());
    File::open(path).ok()?.read_to_end(&mut raw).ok()?;
    let end = raw
        .iter()
        .rposition(|&b| b != b'\n' && b != b'\r')
        .map_or(0, |i| i + 1);
    let pin = std::str::from_utf8(&raw[..end]).ok()?;
    if pin.is_empty() {
        return None;
    }
    Some(AuthPin::from(pin))
}

fn main() -> ExitCode {
    let Some(config) = parse_args(std::env::args().skip(1)) else {
        eprintln!("pkcs11_port: usage: --module PATH --token LABEL --pin-file PATH");
        return ExitCode::from(EXIT_USAGE);
    };
    let Some(pin) = read_pin(&config.pin_file) else {
        eprintln!("pkcs11_port: cannot read the PIN file");
        return ExitCode::from(EXIT_USAGE);
    };
    let hsm = match Hsm::open(&config.module, &config.token, pin) {
        Ok(hsm) => hsm,
        Err(failure) => {
            eprintln!("pkcs11_port: cannot open the token: {}", failure.message);
            return ExitCode::from(EXIT_TOKEN);
        }
    };

    // SAFETY: fd 0 is open for the life of the process; ManuallyDrop keeps it from being closed here.
    let mut input = ManuallyDrop::new(unsafe { File::from_raw_fd(0) });
    // SAFETY: fd 1 is open for the life of the process; ManuallyDrop keeps it from being closed here.
    let mut output = ManuallyDrop::new(unsafe { File::from_raw_fd(1) });

    loop {
        let frame = match read_frame(&mut *input) {
            Ok(Some(frame)) => frame,
            Ok(None) => return ExitCode::SUCCESS,
            Err(_) => return ExitCode::from(EXIT_IO),
        };
        let (response, fatal) = handle(&hsm, &frame);
        drop(frame);
        if write_frame(&mut *output, &response).is_err() {
            return ExitCode::from(EXIT_IO);
        }
        if fatal {
            return ExitCode::from(EXIT_TOKEN);
        }
    }
}

fn read_frame(input: &mut impl Read) -> std::io::Result<Option<Zeroizing<Vec<u8>>>> {
    let mut header = [0u8; 4];
    match input.read_exact(&mut header) {
        Ok(()) => {}
        Err(error) if error.kind() == ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }
    let len = u32::from_be_bytes(header) as usize;
    if len > protocol::MAX_FRAME {
        return Err(ErrorKind::InvalidData.into());
    }
    let mut frame = Zeroizing::new(vec![0u8; len]);
    input.read_exact(&mut frame)?;
    Ok(Some(frame))
}

fn write_frame(output: &mut impl Write, body: &[u8]) -> std::io::Result<()> {
    let len = u32::try_from(body.len()).map_err(|_| ErrorKind::InvalidData)?;
    let mut frame = Zeroizing::new(Vec::with_capacity(4 + body.len()));
    frame.extend_from_slice(&len.to_be_bytes());
    frame.extend_from_slice(body);
    output.write_all(&frame)?;
    output.flush()
}

fn handle(hsm: &Hsm, frame: &[u8]) -> (Zeroizing<Vec<u8>>, bool) {
    let (id, op) = match protocol::decode(frame) {
        Ok(decoded) => decoded,
        Err(error) => {
            return (
                protocol::encode(error.id, error.status, &[error.message.as_bytes()]),
                false,
            );
        }
    };
    match run(hsm, op) {
        Ok(fields) => {
            let refs: Vec<&[u8]> = fields.iter().map(|f| f.as_slice()).collect();
            (protocol::encode(id, Status::Ok, &refs), false)
        }
        Err(failure) => (
            protocol::encode(id, failure.status, &[failure.message.as_bytes()]),
            failure.fatal,
        ),
    }
}

fn run(hsm: &Hsm, op: Op) -> Result<Vec<Zeroizing<Vec<u8>>>, Failure> {
    let fields = match op {
        Op::Ping => {
            hsm.ping()?;
            vec![]
        }
        Op::Sign {
            alg,
            label,
            message,
        } => vec![hsm.sign(alg, &label, &message)?],
        Op::PublicKey { alg, label } => hsm.public_key(alg, &label)?,
        Op::Wrap {
            label,
            aad,
            plaintext,
        } => vec![hsm.wrap(&label, &aad, &plaintext)?],
        Op::Unwrap {
            label,
            aad,
            wrapped,
        } => return Ok(vec![hsm.unwrap(&label, &aad, &wrapped)?]),
    };
    Ok(fields.into_iter().map(Zeroizing::new).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> impl Iterator<Item = String> {
        list.iter()
            .map(|s| s.to_string())
            .collect::<Vec<_>>()
            .into_iter()
    }

    #[test]
    fn tn_63_requires_module_token_and_pin_file() {
        let config = parse_args(args(&[
            "--module",
            "/lib/p11.so",
            "--token",
            "relay",
            "--pin-file",
            "/run/pin",
        ]))
        .unwrap();
        assert_eq!(config.module, "/lib/p11.so");
        assert_eq!(config.token, "relay");
        assert_eq!(config.pin_file, "/run/pin");
        assert!(parse_args(args(&["--module", "/lib/p11.so", "--token", "relay"])).is_none());
        assert!(parse_args(args(&["--pin", "1234"])).is_none());
        assert!(parse_args(args(&["--module", "a", "--module", "b"])).is_none());
        assert!(parse_args(args(&["--module"])).is_none());
    }

    #[test]
    fn tn_63_pin_is_read_from_file_without_trailing_newline() {
        let path = std::env::temp_dir().join(format!("pkcs11_port_pin_{}", std::process::id()));
        std::fs::write(&path, b"1234\n").unwrap();
        assert!(read_pin(path.to_str().unwrap()).is_some());
        std::fs::write(&path, b"\n").unwrap();
        assert!(read_pin(path.to_str().unwrap()).is_none());
        std::fs::remove_file(&path).unwrap();
        assert!(read_pin(path.to_str().unwrap()).is_none());
    }

    #[test]
    fn tn_63_frames_round_trip_and_eof_ends_cleanly() {
        let mut buf = Vec::new();
        write_frame(&mut buf, b"abc").unwrap();
        assert_eq!(buf, [0, 0, 0, 3, b'a', b'b', b'c']);
        let mut reader = buf.as_slice();
        assert_eq!(read_frame(&mut reader).unwrap().unwrap().as_slice(), b"abc");
        assert!(read_frame(&mut reader).unwrap().is_none());
        let mut oversized: &[u8] = &[0xff, 0xff, 0xff, 0xff];
        assert!(read_frame(&mut oversized).is_err());
    }
}

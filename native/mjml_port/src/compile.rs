//! MJML to HTML compilation under Relay's limits: bounded input and output, no `mj-include`, no file system or network access.

use std::io::ErrorKind;

use mrml::prelude::parser::loader::{IncludeLoader, IncludeLoaderError};
use mrml::prelude::parser::{Error as ParseError, ParserOptions, Span};
use mrml::prelude::render::RenderOptions;

/// Largest MJML source accepted, in bytes.
pub const MAX_INPUT: usize = 256 * 1024;

/// Largest HTML output the program ever returns, in bytes; a request may only lower it.
pub const MAX_OUTPUT: usize = 4 * 1024 * 1024;

const INCLUDE_TAG: &[u8] = b"<mj-include";

/// Failure classes reported to the caller.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    InputTooLarge,
    OutputTooLarge,
    Encoding,
    Include,
    Parse,
    Render,
}

/// A compilation failure with a one-based source position; line and column are zero when unknown.
#[derive(Debug, PartialEq, Eq)]
pub struct Failure {
    pub kind: Kind,
    pub message: String,
    pub line: u32,
    pub column: u32,
}

impl Failure {
    fn new(kind: Kind, message: impl Into<String>) -> Self {
        Failure {
            kind,
            message: message.into(),
            line: 0,
            column: 0,
        }
    }

    fn at(mut self, (line, column): (u32, u32)) -> Self {
        self.line = line;
        self.column = column;
        self
    }
}

#[derive(Debug)]
struct RefuseIncludes;

impl IncludeLoader for RefuseIncludes {
    fn resolve(&self, path: &str) -> Result<String, IncludeLoaderError> {
        Err(IncludeLoaderError::new(path, ErrorKind::PermissionDenied)
            .with_message("mj-include is not allowed"))
    }
}

/// Compiles an MJML document to HTML. The output is a pure function of the input.
pub fn compile(source: &[u8], max_output: usize) -> Result<String, Failure> {
    if source.len() > MAX_INPUT {
        return Err(Failure::new(
            Kind::InputTooLarge,
            format!("MJML source exceeds {MAX_INPUT} bytes"),
        ));
    }
    let text = std::str::from_utf8(source).map_err(|error| {
        let valid = &source[..error.valid_up_to()];
        let text = std::str::from_utf8(valid).unwrap_or_default();
        Failure::new(Kind::Encoding, "MJML source is not valid UTF-8")
            .at(position(text, text.len()))
    })?;
    if let Some(offset) = find_include(text.as_bytes()) {
        return Err(
            Failure::new(Kind::Include, "mj-include is not allowed").at(position(text, offset))
        );
    }
    let options = ParserOptions {
        include_loader: Box::new(RefuseIncludes),
    };
    let parsed =
        mrml::parse_with_options(text, &options).map_err(|error| parse_failure(text, error))?;
    let html = parsed
        .element
        .render(&RenderOptions::default())
        .map_err(|error| Failure::new(Kind::Render, error.to_string()))?;
    let limit = max_output.min(MAX_OUTPUT);
    if html.len() > limit {
        return Err(Failure::new(
            Kind::OutputTooLarge,
            format!("compiled HTML exceeds {limit} bytes"),
        ));
    }
    Ok(html)
}

fn find_include(bytes: &[u8]) -> Option<usize> {
    bytes
        .windows(INCLUDE_TAG.len())
        .position(|window| window.eq_ignore_ascii_case(INCLUDE_TAG))
}

fn parse_failure(text: &str, error: ParseError) -> Failure {
    let message = error.to_string();
    let span = |span: &Span| position(text, span.start);
    match &error {
        ParseError::IncludeLoaderError { position: at, .. } => {
            Failure::new(Kind::Include, "mj-include is not allowed").at(span(at))
        }
        ParseError::UnexpectedElement { position: at, .. }
        | ParseError::UnexpectedToken { position: at, .. }
        | ParseError::MissingAttribute { position: at, .. }
        | ParseError::InvalidAttribute { position: at, .. }
        | ParseError::InvalidFormat { position: at, .. } => {
            Failure::new(Kind::Parse, message).at(span(at))
        }
        ParseError::ParserError { source, .. } => {
            let pos = source.pos();
            Failure::new(Kind::Parse, format!("{message}: {source}")).at((pos.row, pos.col))
        }
        ParseError::EndOfStream { .. } => {
            Failure::new(Kind::Parse, message).at(position(text, text.len()))
        }
        ParseError::SizeLimit { .. } => Failure::new(Kind::InputTooLarge, message),
        ParseError::NoRootNode => Failure::new(Kind::Parse, message),
    }
}

fn position(text: &str, offset: usize) -> (u32, u32) {
    let mut end = offset.min(text.len());
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    let before = &text[..end];
    let line = before.matches('\n').count() + 1;
    let column = before
        .rsplit('\n')
        .next()
        .map_or(0, |last| last.chars().count())
        + 1;
    (
        u32::try_from(line).unwrap_or(u32::MAX),
        u32::try_from(column).unwrap_or(u32::MAX),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const SIMPLE: &str = "<mjml><mj-body><mj-section><mj-column><mj-text>Hello</mj-text></mj-column></mj-section></mj-body></mjml>";

    fn wrap(text: &str) -> String {
        format!(
            "<mjml><mj-body><mj-section><mj-column><mj-text>{text}</mj-text></mj-column></mj-section></mj-body></mjml>"
        )
    }

    #[test]
    fn t_98_compiles_mjml_to_html() {
        let html = compile(SIMPLE.as_bytes(), MAX_OUTPUT).unwrap();
        assert!(html.starts_with("<!doctype html>"));
        assert!(html.contains("Hello"));
    }

    #[test]
    fn t_98_output_is_deterministic() {
        let source = "<mjml><mj-body><mj-navbar><mj-navbar-link href=\"/a\">A</mj-navbar-link></mj-navbar><mj-carousel><mj-carousel-image src=\"https://example.com/a.png\" /><mj-carousel-image src=\"https://example.com/b.png\" /></mj-carousel><mj-section><mj-column><mj-text font-family=\"Roboto, Lato\">Hi</mj-text></mj-column></mj-section></mj-body></mjml>";
        let first = compile(source.as_bytes(), MAX_OUTPUT).unwrap();
        for _ in 0..5 {
            assert_eq!(compile(source.as_bytes(), MAX_OUTPUT).unwrap(), first);
        }
    }

    #[test]
    fn tp_8_liquid_tags_survive_compilation_verbatim() {
        let liquid = "Hi {{ recipient.first_name }}! {% if order.total > 100 %}Free shipping{% endif %}";
        let html = compile(wrap(liquid).as_bytes(), MAX_OUTPUT).unwrap();
        assert!(html.contains("{{ recipient.first_name }}"), "{html}");
        assert!(html.contains("{% if order.total > 100 %}"), "{html}");
        assert!(html.contains("{% endif %}"), "{html}");
    }

    #[test]
    fn t_98_refuses_mj_include_in_body_and_head() {
        for source in [
            "<mjml><mj-body><mj-include path=\"./header.mjml\" /></mj-body></mjml>",
            "<mjml><mj-head><mj-include path=\"/etc/passwd\" type=\"css\" /></mj-head><mj-body /></mjml>",
            "<mjml><mj-body><mj-include path=\"https://example.com/x.mjml\" /></mj-body></mjml>",
            "<mjml><mj-body><mj-include path=\"inline\"><mj-text>x</mj-text></mj-include></mj-body></mjml>",
            "<mjml>\n<mj-body>\n  <MJ-INCLUDE path=\"x\" />\n</mj-body></mjml>",
        ] {
            let failure = compile(source.as_bytes(), MAX_OUTPUT).unwrap_err();
            assert_eq!(failure.kind, Kind::Include, "{source}");
            assert!(failure.line >= 1 && failure.column >= 1);
        }
        let failure = compile(
            b"<mjml>\n<mj-body>\n  <mj-include path=\"x\" />\n</mj-body></mjml>",
            MAX_OUTPUT,
        )
        .unwrap_err();
        assert_eq!((failure.line, failure.column), (3, 3));
    }

    #[test]
    fn t_98_include_loader_refuses_every_path() {
        let error = RefuseIncludes.resolve("./a.mjml").unwrap_err();
        assert_eq!(error.reason, ErrorKind::PermissionDenied);
    }

    #[test]
    fn t_98_malformed_input_is_a_parse_failure_with_position() {
        for source in [
            "<mjml><mj-body><mj-section>",
            "<mjml><mj-body></mj-section></mj-body></mjml>",
            "not mjml at all",
            "",
            "<mjml><mj-body><mj-section><mj-column><mj-text>x</mj-column></mj-section></mj-body></mjml>",
            "<mjml><mj-body><mj-image src=\"a.png\" alt=\"x></mj-body></mjml>",
        ] {
            let failure = compile(source.as_bytes(), MAX_OUTPUT).unwrap_err();
            assert_eq!(failure.kind, Kind::Parse, "{source}: {failure:?}");
            assert!(!failure.message.is_empty());
        }
        let failure = compile(b"<mjml>\n<mj-body>\n</mj-section>", MAX_OUTPUT).unwrap_err();
        assert_eq!(failure.kind, Kind::Parse);
        assert!(failure.line >= 1);
    }

    #[test]
    fn tp_6_input_above_256_kib_is_refused() {
        let filler = "a".repeat(MAX_INPUT);
        let failure = compile(wrap(&filler).as_bytes(), MAX_OUTPUT).unwrap_err();
        assert_eq!(failure.kind, Kind::InputTooLarge);
        let source = wrap(&"a".repeat(MAX_INPUT - 200));
        assert!(source.len() <= MAX_INPUT);
        assert!(compile(source.as_bytes(), MAX_OUTPUT).is_ok());
    }

    #[test]
    fn t_98_output_above_the_limit_is_refused() {
        let failure = compile(SIMPLE.as_bytes(), 100).unwrap_err();
        assert_eq!(failure.kind, Kind::OutputTooLarge);
        let html = compile(SIMPLE.as_bytes(), MAX_OUTPUT).unwrap();
        assert!(compile(SIMPLE.as_bytes(), html.len()).is_ok());
        assert!(compile(SIMPLE.as_bytes(), usize::MAX).is_ok());
    }

    #[test]
    fn t_98_invalid_utf8_is_refused_with_position() {
        let failure = compile(b"<mjml>\nab\xff</mjml>", MAX_OUTPUT).unwrap_err();
        assert_eq!(failure.kind, Kind::Encoding);
        assert_eq!((failure.line, failure.column), (2, 3));
    }

    #[test]
    fn t_98_positions_count_lines_and_characters() {
        assert_eq!(position("abc", 0), (1, 1));
        assert_eq!(position("ab\ncd", 4), (2, 2));
        assert_eq!(position("ğü\nx", 4), (1, 3));
        assert_eq!(position("ğ", 1), (1, 1));
        assert_eq!(position("abc", 99), (1, 4));
    }
}

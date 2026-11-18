//! Parquet writing and reading of archived rows. Every column is an optional UTF-8 byte array holding the PostgreSQL text form of its value; the digest is SHA-256 over the canonical encoding of the rows in file order, where each value is `0` for null or `1`, a four-byte big-endian length and the bytes.

use std::fs::{File, OpenOptions};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use parquet::basic::{Compression, LogicalType, Repetition, Type as PhysicalType};
use parquet::data_type::{ByteArray, ByteArrayType};
use parquet::errors::ParquetError;
use parquet::file::properties::WriterProperties;
use parquet::file::reader::{FileReader, SerializedFileReader};
use parquet::file::writer::SerializedFileWriter;
use parquet::record::reader::RowIter;
use parquet::record::{Field, Row};
use parquet::schema::types::Type;
use sha2::{Digest, Sha256};

/// Rows buffered before a row group is written.
pub const ROW_GROUP_ROWS: usize = 65_536;

/// Value bytes buffered before a row group is written.
pub const ROW_GROUP_BYTES: usize = 64 * 1024 * 1024;

/// A failure while writing or reading an archive file.
#[derive(Debug)]
pub enum Error {
    Io(std::io::Error),
    Parquet(ParquetError),
    Encoding,
    Shape(&'static str),
}

impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Error::Io(error)
    }
}

impl From<ParquetError> for Error {
    fn from(error: ParquetError) -> Self {
        Error::Parquet(error)
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Io(error) => write!(f, "io: {error}"),
            Error::Parquet(error) => write!(f, "parquet: {error}"),
            Error::Encoding => f.write_str("a value is not valid UTF-8"),
            Error::Shape(message) => f.write_str(message),
        }
    }
}

/// Row count, digest and size of an archive file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Summary {
    pub rows: u64,
    pub digest: [u8; 32],
    pub bytes: u64,
}

/// A Parquet file being written.
pub struct Writer {
    path: PathBuf,
    inner: SerializedFileWriter<File>,
    values: Vec<Vec<ByteArray>>,
    levels: Vec<Vec<i16>>,
    buffered_rows: usize,
    buffered_bytes: usize,
    rows: u64,
    hasher: Sha256,
}

impl Writer {
    /// Creates a new file at `path` with one column per name; refuses a path that exists.
    pub fn create(path: &Path, names: &[String]) -> Result<Self, Error> {
        if names.is_empty() {
            return Err(Error::Shape("a table has at least one column"));
        }
        let fields = names
            .iter()
            .map(|name| {
                Type::primitive_type_builder(name, PhysicalType::BYTE_ARRAY)
                    .with_repetition(Repetition::OPTIONAL)
                    .with_logical_type(Some(LogicalType::String))
                    .build()
                    .map(Arc::new)
            })
            .collect::<Result<Vec<_>, _>>()?;
        let schema = Type::group_type_builder("relay_archive")
            .with_fields(fields)
            .build()?;
        let properties = WriterProperties::builder()
            .set_compression(Compression::SNAPPY)
            .set_created_by("relay archive_port".to_owned())
            .build();
        let file = OpenOptions::new().write(true).create_new(true).open(path)?;
        let inner = SerializedFileWriter::new(file, Arc::new(schema), Arc::new(properties))?;
        Ok(Writer {
            path: path.to_path_buf(),
            inner,
            values: vec![Vec::new(); names.len()],
            levels: vec![Vec::new(); names.len()],
            buffered_rows: 0,
            buffered_bytes: 0,
            rows: 0,
            hasher: Sha256::new(),
        })
    }

    /// Number of columns of the file.
    pub fn columns(&self) -> usize {
        self.levels.len()
    }

    /// Appends one row given as its canonical encoding and its values.
    pub fn push(&mut self, raw: &[u8], values: &[Option<&[u8]>]) -> Result<(), Error> {
        if values.len() != self.columns() {
            return Err(Error::Shape("row width differs from the columns"));
        }
        for value in values.iter().flatten() {
            std::str::from_utf8(value).map_err(|_| Error::Encoding)?;
        }
        self.hasher.update(raw);
        for (index, value) in values.iter().enumerate() {
            match value {
                Some(bytes) => {
                    self.values[index].push(ByteArray::from(bytes.to_vec()));
                    self.levels[index].push(1);
                    self.buffered_bytes += bytes.len();
                }
                None => self.levels[index].push(0),
            }
        }
        self.buffered_rows += 1;
        self.rows += 1;
        if self.buffered_rows >= ROW_GROUP_ROWS || self.buffered_bytes >= ROW_GROUP_BYTES {
            self.flush()?;
        }
        Ok(())
    }

    fn flush(&mut self) -> Result<(), Error> {
        if self.buffered_rows == 0 {
            return Ok(());
        }
        let mut group = self.inner.next_row_group()?;
        let mut index = 0;
        while let Some(mut column) = group.next_column()? {
            let values = self
                .values
                .get(index)
                .ok_or(Error::Shape("file has more columns than the schema"))?;
            column.typed::<ByteArrayType>().write_batch(
                values,
                Some(self.levels[index].as_slice()),
                None,
            )?;
            column.close()?;
            index += 1;
        }
        let _group = group.close()?;
        for column in &mut self.values {
            column.clear();
        }
        for column in &mut self.levels {
            column.clear();
        }
        self.buffered_rows = 0;
        self.buffered_bytes = 0;
        Ok(())
    }

    /// Writes the remaining rows and the footer and returns the file's summary.
    pub fn finish(mut self) -> Result<Summary, Error> {
        self.flush()?;
        let _metadata = self.inner.close()?;
        let bytes = std::fs::metadata(&self.path)?.len();
        Ok(Summary {
            rows: self.rows,
            digest: digest(self.hasher),
            bytes,
        })
    }
}

fn digest(hasher: Sha256) -> [u8; 32] {
    let mut out = [0u8; 32];
    out.copy_from_slice(&hasher.finalize());
    out
}

fn length(len: usize) -> Result<[u8; 4], Error> {
    u32::try_from(len)
        .map(u32::to_be_bytes)
        .map_err(|_| Error::Shape("a value is longer than 4 GiB"))
}

fn column_names(reader: &SerializedFileReader<File>) -> Vec<String> {
    reader
        .metadata()
        .file_metadata()
        .schema_descr()
        .columns()
        .iter()
        .map(|column| column.name().to_owned())
        .collect()
}

fn encode_row(row: &Row, width: usize, out: &mut Vec<u8>) -> Result<(), Error> {
    let mut seen = 0usize;
    for (_name, field) in row.get_column_iter() {
        match field {
            Field::Null => out.push(0),
            Field::Str(text) => {
                out.push(1);
                out.extend_from_slice(&length(text.len())?);
                out.extend_from_slice(text.as_bytes());
            }
            _ => return Err(Error::Shape("a column is not a UTF-8 byte array")),
        }
        seen += 1;
    }
    if seen == width {
        Ok(())
    } else {
        Err(Error::Shape("row width differs from the columns"))
    }
}

/// Reads an archive file back and returns its summary and column names.
pub fn verify(path: &Path) -> Result<(Summary, Vec<String>), Error> {
    let bytes = std::fs::metadata(path)?.len();
    let (mut reader, names) = Reader::open(path)?;
    let mut hasher = Sha256::new();
    let mut rows = 0u64;
    loop {
        let (count, batch) = reader.next_batch(ROW_GROUP_ROWS, ROW_GROUP_BYTES)?;
        if count == 0 {
            break;
        }
        hasher.update(&batch);
        rows += u64::from(count);
    }
    Ok((
        Summary {
            rows,
            digest: digest(hasher),
            bytes,
        },
        names,
    ))
}

/// An archive file being read back row by row in file order.
pub struct Reader {
    rows: RowIter<'static>,
    width: usize,
}

impl Reader {
    /// Opens a file and returns the reader with the file's column names.
    pub fn open(path: &Path) -> Result<(Self, Vec<String>), Error> {
        let reader = SerializedFileReader::new(File::open(path)?)?;
        let names = column_names(&reader);
        let rows = RowIter::from_file_into(Box::new(reader));
        let width = names.len();
        Ok((Reader { rows, width }, names))
    }

    /// Returns the next rows in their canonical encoding, at most `max_rows` of them and stopping once `max_bytes` is reached; a count of zero marks the end of the file.
    pub fn next_batch(
        &mut self,
        max_rows: usize,
        max_bytes: usize,
    ) -> Result<(u32, Vec<u8>), Error> {
        let mut out = Vec::new();
        let mut count = 0usize;
        while count < max_rows && out.len() < max_bytes {
            match self.rows.next() {
                Some(row) => {
                    encode_row(&row?, self.width, &mut out)?;
                    count += 1;
                }
                None => break,
            }
        }
        let count = u32::try_from(count).map_err(|_| Error::Shape("batch is too large"))?;
        Ok((count, out))
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static NEXT: AtomicUsize = AtomicUsize::new(0);

    pub fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "archive_port_{}_{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join(name)
    }

    pub fn encode(row: &[Option<&str>]) -> Vec<u8> {
        let mut out = Vec::new();
        for value in row {
            match value {
                None => out.push(0),
                Some(text) => {
                    out.push(1);
                    out.extend_from_slice(&(text.len() as u32).to_be_bytes());
                    out.extend_from_slice(text.as_bytes());
                }
            }
        }
        out
    }

    fn write(path: &Path, names: &[&str], rows: &[Vec<Option<&str>>]) -> Summary {
        let names: Vec<String> = names.iter().map(|name| (*name).to_owned()).collect();
        let mut writer = Writer::create(path, &names).unwrap();
        for row in rows {
            let values: Vec<Option<&[u8]>> = row.iter().map(|v| v.map(str::as_bytes)).collect();
            writer.push(&encode(row), &values).unwrap();
        }
        writer.finish().unwrap()
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    #[test]
    fn op_84_the_digest_matches_the_shared_vector() {
        let path = scratch("vector.parquet");
        let rows = vec![
            vec![Some("1"), Some("alpha")],
            vec![Some("2"), None],
            vec![Some("3"), Some("")],
        ];
        let written = write(&path, &["id", "name"], &rows);
        assert_eq!(written.rows, 3);
        assert_eq!(
            hex(&written.digest),
            "8320119bf45f4d4e744ca70365f776d3305899a6af1dff66d2905938bb32ef60"
        );
        let (read, names) = verify(&path).unwrap();
        assert_eq!(read, written);
        assert_eq!(names, ["id", "name"]);
    }

    #[test]
    fn op_84_an_empty_table_round_trips() {
        let path = scratch("empty.parquet");
        let written = write(&path, &["id"], &[]);
        assert_eq!(written.rows, 0);
        assert_eq!(
            hex(&written.digest),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(verify(&path).unwrap().0, written);
    }

    #[test]
    fn op_84_many_row_groups_round_trip_in_order() {
        let path = scratch("many.parquet");
        let ids: Vec<String> = (0..(ROW_GROUP_ROWS * 2 + 7))
            .map(|i| i.to_string())
            .collect();
        let rows: Vec<Vec<Option<&str>>> = ids
            .iter()
            .enumerate()
            .map(|(i, id)| vec![Some(id.as_str()), (i % 3 == 0).then_some("x")])
            .collect();
        let written = write(&path, &["id", "flag"], &rows);
        assert_eq!(written.rows, rows.len() as u64);
        assert_eq!(verify(&path).unwrap().0, written);
    }

    #[test]
    fn op_84_a_tampered_file_is_refused() {
        let path = scratch("tampered.parquet");
        write(&path, &["id"], &[vec![Some("1")]]);
        let mut bytes = std::fs::read(&path).unwrap();
        let len = bytes.len();
        bytes.truncate(len - 9);
        std::fs::write(&path, bytes).unwrap();
        assert!(verify(&path).is_err());
    }

    #[test]
    fn op_84_the_writer_refuses_bad_input() {
        let path = scratch("bad.parquet");
        let names = vec!["id".to_owned()];
        let mut writer = Writer::create(&path, &names).unwrap();
        assert!(matches!(
            writer.push(&[1, 0, 0, 0, 1, 0xff], &[Some(&[0xff][..])]),
            Err(Error::Encoding)
        ));
        assert!(matches!(
            writer.push(&[0, 0], &[None, None]),
            Err(Error::Shape(_))
        ));
        assert!(matches!(Writer::create(&path, &names), Err(Error::Io(_))));
        assert!(matches!(
            Writer::create(&scratch("none.parquet"), &[]),
            Err(Error::Shape(_))
        ));
    }
}

use flate2::read::GzDecoder;
#[cfg(feature = "save_kdbx4")]
use flate2::write::GzEncoder;
#[cfg(feature = "save_kdbx4")]
use flate2::Compression as Flate2Compression;
use std::convert::TryFrom;
use std::io::Read;
#[cfg(feature = "save_kdbx4")]
use std::io::Write;

pub trait Compression {
    #[cfg(feature = "save_kdbx4")]
    fn compress(&self, in_buffer: &[u8]) -> Result<Vec<u8>, std::io::Error>;
    fn decompress(&self, in_buffer: &[u8]) -> Result<Vec<u8>, std::io::Error>;
    fn decompress_limited(&self, in_buffer: &[u8], max: usize) -> Result<Vec<u8>, std::io::Error>;
}

pub struct NoCompression;

impl Compression for NoCompression {
    #[cfg(feature = "save_kdbx4")]
    fn compress(&self, in_buffer: &[u8]) -> Result<Vec<u8>, std::io::Error> {
        Ok(in_buffer.to_vec())
    }
    fn decompress(&self, in_buffer: &[u8]) -> Result<Vec<u8>, std::io::Error> {
        Ok(in_buffer.to_vec())
    }
    fn decompress_limited(&self, in_buffer: &[u8], max: usize) -> Result<Vec<u8>, std::io::Error> {
        if in_buffer.len() > max {
            return Err(std::io::Error::other(crate::db::ResourceLimitError));
        }
        self.decompress(in_buffer)
    }
}

pub struct GZipCompression;

impl Compression for GZipCompression {
    #[cfg(feature = "save_kdbx4")]
    fn compress(&self, in_buffer: &[u8]) -> Result<Vec<u8>, std::io::Error> {
        let mut res = Vec::new();
        let mut encoder = GzEncoder::new(&mut res, Flate2Compression::default());
        encoder.write_all(in_buffer)?;
        encoder.flush()?;
        encoder.finish()?;
        Ok(res)
    }
    fn decompress(&self, in_buffer: &[u8]) -> Result<Vec<u8>, std::io::Error> {
        let mut res = Vec::new();
        let mut decoder = GzDecoder::new(in_buffer);
        decoder.read_to_end(&mut res)?;
        Ok(res)
    }
    fn decompress_limited(&self, in_buffer: &[u8], max: usize) -> Result<Vec<u8>, std::io::Error> {
        let mut res = Vec::new();
        // Read at most one byte past the bound; never trust the gzip size trailer.
        let read_limit = u64::try_from(max).unwrap_or(u64::MAX).saturating_add(1);
        GzDecoder::new(in_buffer)
            .take(read_limit)
            .read_to_end(&mut res)?;
        if res.len() > max {
            return Err(std::io::Error::other(crate::db::ResourceLimitError));
        }
        Ok(res)
    }
}

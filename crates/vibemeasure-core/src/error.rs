use thiserror::Error;

pub type Result<T> = std::result::Result<T, VibeError>;

#[derive(Debug, Error)]
pub enum VibeError {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),

    #[error("XLSX error: {0}")]
    Xlsx(#[from] rust_xlsxwriter::XlsxError),

    #[error("XML error: {0}")]
    Xml(#[from] quick_xml::Error),

    #[error("HTTP error: {0}")]
    Http(String),

    #[error("invalid data: {0}")]
    InvalidData(String),
}

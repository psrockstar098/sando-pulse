//! Error sets shared across Pulse modules.

pub const PulseError = error{
    ConfigMissing,
    ConfigInvalid,
    AuthRequired,
    AuthInvalid,
    RateLimited,
    InvalidRequest,
    SourceUnavailable,
    StorageUnavailable,
    IngestFailed,
    MigrationFailed,
    NotFound,
    OutOfMemory,
};

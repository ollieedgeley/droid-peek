//! Pure, testable contracts for the Omarchy Android local helper.
//!
//! Process execution, mDNS discovery, persistence, and device input are added
//! only after their Phase 0 contracts have explicit tests.

pub mod pairing;
pub mod process;
pub mod protocol;
pub mod qr;
pub mod runtime;
pub mod wireless;

pub use protocol::PROTOCOL_VERSION;

/// A non-secret event emitted when the helper is ready to accept work.
#[must_use]
pub fn ready_event() -> String {
    protocol::Event::Ready.to_line()
}

#[cfg(test)]
mod tests {
    use super::{PROTOCOL_VERSION, ready_event};

    #[test]
    fn ready_event_is_versioned_and_secret_free() {
        assert_eq!(
            ready_event(),
            format!(r#"{{"version":{PROTOCOL_VERSION},"type":"ready"}}"#)
        );
        assert!(!ready_event().contains("secret"));
    }
}

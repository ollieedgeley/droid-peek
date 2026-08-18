#![forbid(unsafe_code)]
#![cfg_attr(not(test), deny(clippy::expect_used, clippy::unwrap_used))]
#![deny(clippy::todo, clippy::unimplemented)]

//! Pure, testable contracts for the Omarchy Android local helper.
//!
//! Process execution, mDNS discovery, persistence, and device input are added
//! only after their Phase 0 contracts have explicit tests.

pub mod actions;
pub mod input;
pub mod pairing;
pub mod persistence;
pub mod preferences;
pub mod private_fs;
pub mod process;
pub mod protocol;
pub mod qr;
pub mod runtime;
pub mod scrcpy_config;
pub mod session;
pub mod wireless;

pub use protocol::PROTOCOL_VERSION;

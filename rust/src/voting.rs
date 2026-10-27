//! C FFI for the voting functionality, backed by upstream `zcash_voting` 1.0.
//!
//! Implementation is split into submodules for navigation. Exported FFI functions
//! keep their stable C symbols with `#[unsafe(no_mangle)]`. Entry points that the
//! crate's 1.0 one-shot commit flow absorbed (`encrypt_shares`, `sign_cast_vote`,
//! `store_commitment_bundle`, `decompose_weight`, `generate_delegation_inputs`)
//! keep their symbols as honest "superseded" error stubs.
//!
//! This module is compiled only with the non-default `voting` Cargo feature. It is currently
//! disabled because `zcash_voting` has no stable release on the librustzcash crate line this
//! library uses.

compile_error!(
    "The `voting` feature is currently unsupported: no stable `zcash_voting` release targets \
     the librustzcash crate line this library uses. Add a compatible, permissively licensed \
     `zcash_voting` as an optional dependency in Cargo.toml and list it in the `voting` feature \
     before enabling it."
);

pub mod confirmation;
mod constants;
pub mod db;
pub mod delegation;
pub mod ffi_types;
pub mod helpers;
pub mod json;
pub mod notes;
pub mod progress;
pub mod recovery;
pub mod rounds;
pub mod share_tracking;
pub mod signing;
#[cfg(test)]
pub(crate) mod test_helpers;
pub mod tree;
pub mod util;
pub mod vote;

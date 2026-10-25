use std::fmt::Write;

use sha_crypt::{Sha512Params, sha512_crypt_b64};

use super::{AccountId, Dataset, STREAM_PASSWORD};
use crate::error::{Error, Result};
use crate::rng::Rng;

const SALT_ALPHABET: &[u8; 64] =
    b"./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const SALT_LEN: usize = 16;
const PASSWORD_ROUNDS: usize = 5_000;

impl Dataset {
    pub fn password(&self, account: AccountId) -> String {
        let mut rng = Rng::from_parts(&[self.seed, STREAM_PASSWORD, self.ordinal(account)]);
        let mut out = String::with_capacity(24);
        let _ = write!(out, "Mb-{:016x}", rng.next_u64());
        out
    }

    pub fn password_hash(&self, account: AccountId) -> Result<String> {
        let mut rng = Rng::from_parts(&[self.seed, STREAM_PASSWORD, self.ordinal(account), 1]);
        let salt: String = (0..SALT_LEN)
            .map(|_| char::from(SALT_ALPHABET[rng.below_usize(SALT_ALPHABET.len())]))
            .collect();
        let params = Sha512Params::new(PASSWORD_ROUNDS)
            .map_err(|err| Error::config(format!("sha512-crypt params: {err:?}")))?;
        let hash = sha512_crypt_b64(self.password(account).as_bytes(), salt.as_bytes(), &params)
            .map_err(|err| Error::config(format!("sha512-crypt: {err:?}")))?;
        Ok(format!("$6${salt}${hash}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dataset::{DEFAULT_SEED, DatasetName};

    #[test]
    fn hash_verifies() {
        let ds = Dataset::new(DatasetName::Tiny, DEFAULT_SEED, "example.org");
        let account = AccountId::Regular(1);
        let hash = ds.password_hash(account).expect("hash");
        assert!(hash.starts_with("$6$"));
        assert_eq!(hash.len(), 3 + SALT_LEN + 1 + 86);
        assert!(sha_crypt::sha512_check(&ds.password(account), &hash).is_ok());
        assert_eq!(hash, ds.password_hash(account).expect("hash"));
    }
}

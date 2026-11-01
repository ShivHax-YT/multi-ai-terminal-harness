//! Bounded scrollback with a sequence number per chunk. In memory only (rule 4).

use std::collections::VecDeque;

pub(crate) struct Ring {
    bytes: VecDeque<u8>,
    cap: usize,
    seq: u64,
}

impl Ring {
    pub(crate) fn new(cap: usize) -> Ring {
        Ring {
            bytes: VecDeque::new(),
            cap,
            seq: 0,
        }
    }

    /// Appends one chunk, dropping the oldest bytes past the cap. Returns the chunk's `seq`.
    pub(crate) fn push(&mut self, chunk: &[u8]) -> u64 {
        self.bytes.extend(chunk);
        let excess = self.bytes.len().saturating_sub(self.cap);
        self.bytes.drain(..excess);
        self.seq += 1;
        self.seq
    }

    /// The `seq` of the newest chunk, and everything still held.
    pub(crate) fn snapshot(&self) -> (u64, Vec<u8>) {
        (self.seq, self.bytes.iter().copied().collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_only_the_newest_bytes_and_counts_every_chunk() {
        let mut ring = Ring::new(4);
        assert_eq!(ring.push(b"abc"), 1);
        assert_eq!(ring.push(b"def"), 2);
        assert_eq!(ring.snapshot(), (2, b"cdef".to_vec()));
    }
}

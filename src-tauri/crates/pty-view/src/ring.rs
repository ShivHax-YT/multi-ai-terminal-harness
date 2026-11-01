//! Bounded scrollback with a sequence number per chunk. In memory only (rule 4).
//!
//! Private mode changes (bracketed paste, mouse, alternate screen) are remembered. Once the ring has dropped the
//! bytes that turned them on, a fresh xterm would otherwise replay the tail without those modes.

use std::collections::{BTreeSet, VecDeque};

/// DEC private modes a reattached view has to restore when the original sequence has scrolled away.
const TRACKED_MODES: [u16; 8] = [47, 1000, 1002, 1003, 1006, 1047, 1049, 2004];

pub(crate) struct Ring {
    bytes: VecDeque<u8>,
    cap: usize,
    seq: u64,
    wrapped: bool,
    modes: ModeSet,
}

impl Ring {
    pub(crate) fn new(cap: usize) -> Ring {
        Ring {
            bytes: VecDeque::new(),
            cap,
            seq: 0,
            wrapped: false,
            modes: ModeSet::default(),
        }
    }

    /// Appends one chunk, dropping the oldest bytes past the cap. Returns the chunk's `seq`.
    pub(crate) fn push(&mut self, chunk: &[u8]) -> u64 {
        self.modes.observe(chunk);
        self.bytes.extend(chunk);
        let excess = self.bytes.len().saturating_sub(self.cap);
        if excess > 0 {
            self.bytes.drain(..excess);
            self.wrapped = true;
        }
        self.seq += 1;
        self.seq
    }

    /// The `seq` of the newest chunk, and everything still held.
    ///
    /// After the ring has wrapped, the current private modes are prefixed so a new xterm enables them before it
    /// replays the tail. The prefix is not a new chunk and does not change `seq`.
    pub(crate) fn snapshot(&self) -> (u64, Vec<u8>) {
        let mut out = Vec::new();
        if self.wrapped {
            out.extend(self.modes.restore());
        }
        out.extend(self.bytes.iter().copied());
        (self.seq, out)
    }
}

#[derive(Default)]
struct ModeSet {
    on: BTreeSet<u16>,
    /// A CSI that was cut off at a chunk boundary.
    pending: Vec<u8>,
}

impl ModeSet {
    fn observe(&mut self, chunk: &[u8]) {
        self.pending.extend_from_slice(chunk);
        let data = std::mem::take(&mut self.pending);
        let bytes = data.as_slice();
        let mut index = 0;
        while index < bytes.len() {
            if bytes[index] != 0x1b {
                index += 1;
                continue;
            }
            if index + 1 >= bytes.len() {
                self.pending.extend_from_slice(&bytes[index..]);
                break;
            }
            if bytes[index + 1] != b'[' {
                index += 1;
                continue;
            }
            let mut cursor = index + 2;
            let private = cursor < bytes.len() && bytes[cursor] == b'?';
            if private {
                cursor += 1;
            }
            let params_at = cursor;
            while cursor < bytes.len() && !(0x40..=0x7e).contains(&bytes[cursor]) {
                cursor += 1;
            }
            if cursor >= bytes.len() {
                if bytes.len() - index <= 48 {
                    self.pending.extend_from_slice(&bytes[index..]);
                }
                break;
            }
            let final_byte = bytes[cursor];
            if private && (final_byte == b'h' || final_byte == b'l') {
                self.apply(&bytes[params_at..cursor], final_byte == b'h');
            }
            index = cursor + 1;
        }
    }

    fn apply(&mut self, params: &[u8], enable: bool) {
        for part in params.split(|byte| *byte == b';') {
            if part.is_empty() || !part.iter().all(u8::is_ascii_digit) {
                continue;
            }
            let Ok(text) = std::str::from_utf8(part) else {
                continue;
            };
            let Ok(mode) = text.parse::<u16>() else {
                continue;
            };
            if !TRACKED_MODES.contains(&mode) {
                continue;
            }
            if enable {
                self.on.insert(mode);
            } else {
                self.on.remove(&mode);
            }
        }
    }

    fn restore(&self) -> Vec<u8> {
        let mut out = Vec::new();
        for mode in TRACKED_MODES {
            if self.on.contains(&mode) {
                out.extend(format!("\u{1b}[?{mode}h").into_bytes());
            }
        }
        out
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

    #[test]
    fn an_unwrapped_ring_replays_bytes_exactly() {
        let mut ring = Ring::new(64);
        ring.push(b"\x1b[?2004hhello");
        assert_eq!(ring.snapshot().1, b"\x1b[?2004hhello");
    }

    #[test]
    fn a_wrapped_ring_restores_bracketed_paste_before_the_tail() {
        let mut ring = Ring::new(8);
        ring.push(b"\x1b[?2004h");
        ring.push(b"0123456789abcdef");
        let bytes = ring.snapshot().1;
        assert!(bytes.starts_with(b"\x1b[?2004h"));
        assert!(bytes.ends_with(b"89abcdef"));
    }

    #[test]
    fn a_mode_that_was_turned_off_is_not_restored() {
        let mut ring = Ring::new(4);
        ring.push(b"\x1b[?2004h");
        ring.push(b"\x1b[?2004l");
        ring.push(b"0123456789");
        let bytes = ring.snapshot().1;
        assert!(!bytes.windows(8).any(|window| window == b"\x1b[?2004h"));
    }

    #[test]
    fn a_mode_sequence_split_across_chunks_is_still_restored() {
        let mut ring = Ring::new(4);
        ring.push(b"\x1b[?20");
        ring.push(b"04h");
        ring.push(b"0123456789");
        assert!(ring.snapshot().1.starts_with(b"\x1b[?2004h"));
    }
}

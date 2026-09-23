//! Where a reader outside this process types into a hosted session: a Unix socket per session.
//! Each connection carries one message - its length as eight big-endian bytes, then that many
//! bytes - and a message that does not arrive whole is dropped, so a half-sent paste never leaves
//! the CLI waiting for its end. Messages are written to the child's pty in the order they came,
//! on a thread of their own, so a busy child never keeps the next connection waiting, and each
//! connection is answered with one byte: 1 if its message was taken, 0 if it was refused. The
//! web console is its one writer.
//!
//! In a directory only this user can enter, under the temporary directory rather than the
//! consumer's `.cerebro/state`, since a socket's path is capped at about a hundred bytes and a
//! consumer root may be deep.

use std::{
    io::{Read, Write},
    os::unix::{fs::PermissionsExt, net::UnixListener, net::UnixStream},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

/// The most one message may type; a longer one is dropped.
const INPUT_LIMIT: u64 = 256 * 1024;

/// How many messages may wait for a child slow to read before more are refused.
const QUEUED: usize = 16;

/// How much of a message is written to the pty at a time.
const PIECE: usize = 4096;

/// How long a connection may take to say what it types before it is dropped, so one stuck
/// writer holds up the others by no more than this.
const INPUT_TIMEOUT: Duration = Duration::from_secs(2);

pub type Writer = Arc<Mutex<Box<dyn Write + Send>>>;

pub struct Inbox {
    path: PathBuf,
    stop: Arc<AtomicBool>,
}

impl Inbox {
    /// Listen at `<temp>/cerebro-<pid>/<file>` and write what arrives through WRITER.
    pub fn open(file: &str, writer: Writer) -> std::io::Result<Self> {
        let (listener, path) = bind(file)?;
        Ok(Self::serve(listener, path, writer))
    }

    #[cfg(test)]
    fn open_at(path: &Path, writer: Writer) -> std::io::Result<Self> {
        let _ = std::fs::remove_file(path);
        Ok(Self::serve(UnixListener::bind(path)?, path.to_path_buf(), writer))
    }

    fn serve(listener: UnixListener, path: PathBuf, writer: Writer) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let (typed, typing) = std::sync::mpsc::sync_channel::<Vec<u8>>(QUEUED);
        std::thread::spawn(move || {
            for bytes in typing {
                // A piece at a time, so a child slow to read holds the view's own keyboard up
                // for one piece and not for a whole paste.
                for piece in bytes.chunks(PIECE) {
                    let mut writer = writer.lock().unwrap_or_else(|e| e.into_inner());
                    if writer.write_all(piece).is_err() {
                        break;
                    }
                    let _ = writer.flush();
                }
            }
        });
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                if thread_stop.load(Ordering::SeqCst) {
                    break;
                }
                let Ok(mut stream) = stream else { continue };
                let _ = stream.set_read_timeout(Some(INPUT_TIMEOUT));
                let Some(bytes) = message(&mut stream) else { continue };
                if thread_stop.load(Ordering::SeqCst) {
                    break;
                }
                // The sender learns whether it was taken: a child that stopped reading refuses
                // more once `QUEUED` messages wait, rather than the view holding them all.
                let taken = match typed.try_send(bytes) {
                    Ok(()) => true,
                    Err(std::sync::mpsc::TrySendError::Full(_)) => false,
                    Err(std::sync::mpsc::TrySendError::Disconnected(_)) => break,
                };
                let _ = stream.write_all(&[u8::from(taken)]);
            }
        });
        Self { path, stop }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// A listener at `<temp>/cerebro-<pid>/<file>`, in a directory only this user can enter.
pub fn bind(file: &str) -> std::io::Result<(UnixListener, PathBuf)> {
    let dir = std::env::temp_dir().join(format!("cerebro-{}", std::process::id()));
    let path = dir.join(file);
    // Again if the last socket before this one took the directory away in between.
    let mut tries = 3;
    loop {
        let bound = std::fs::create_dir_all(&dir)
            .and_then(|()| std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)))
            .and_then(|()| {
                let _ = std::fs::remove_file(&path);
                UnixListener::bind(&path)
            });
        match bound {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound && tries > 1 => tries -= 1,
            bound => return bound.map(|listener| (listener, path)),
        }
    }
}

/// Stop a listener serving PATH by connecting to it once STOP is set, then take its file away,
/// and the directory with the last of them.
pub fn close(path: &Path, stop: &AtomicBool) {
    stop.store(true, Ordering::SeqCst);
    let _ = UnixStream::connect(path);
    let _ = std::fs::remove_file(path);
    if let Some(dir) = path.parent() {
        let _ = std::fs::remove_dir(dir);
    }
}

/// One whole message from STREAM, or `None` for one that is empty, too long or cut short.
pub fn message(stream: &mut impl Read) -> Option<Vec<u8>> {
    let mut length = [0u8; 8];
    stream.read_exact(&mut length).ok()?;
    let length = u64::from_be_bytes(length);
    if length == 0 || length > INPUT_LIMIT {
        return None;
    }
    let mut bytes = vec![0u8; length as usize];
    stream.read_exact(&mut bytes).ok()?;
    Some(bytes)
}

/// BYTES as one message.
pub fn framed(bytes: &[u8]) -> Vec<u8> {
    let mut message = (bytes.len() as u64).to_be_bytes().to_vec();
    message.extend_from_slice(bytes);
    message
}

impl Drop for Inbox {
    fn drop(&mut self) {
        close(&self.path, &self.stop);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A pty whose child has stopped reading.
    struct Stuck(std::sync::mpsc::Receiver<()>);

    impl Write for Stuck {
        fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
            let _ = self.0.recv();
            Err(std::io::ErrorKind::BrokenPipe.into())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn a_child_that_stopped_reading_refuses_more_than_its_queue() {
        let dir = tempfile::tempdir().unwrap();
        let (release, stuck) = std::sync::mpsc::channel();
        let inbox = Inbox::open_at(&dir.path().join("in.sock"), Arc::new(Mutex::new(Box::new(Stuck(stuck))))).unwrap();
        let answer = || {
            let mut stream = UnixStream::connect(inbox.path()).unwrap();
            stream.write_all(&framed(b"x")).unwrap();
            let mut taken = [9u8; 1];
            stream.read_exact(&mut taken).unwrap();
            taken[0]
        };

        let answers: Vec<u8> = (0..QUEUED + 3).map(|_| answer()).collect();

        assert_eq!(answers[0], 1);
        assert_eq!(*answers.last().unwrap(), 0, "{answers:?}");
        drop(release);
    }

    #[test]
    fn a_message_is_typed_only_when_it_arrived_whole() {
        assert_eq!(message(&mut framed(b"hello\r").as_slice()), Some(b"hello\r".to_vec()));
        let whole = framed(b"\x1b[200~pasted\x1b[201~");
        assert_eq!(message(&mut &whole[..whole.len() - 1]), None, "a paste cut short");
        assert_eq!(message(&mut &b"hello"[..]), None, "no length");
        assert_eq!(message(&mut framed(b"").as_slice()), None);
        let mut long = (INPUT_LIMIT + 1).to_be_bytes().to_vec();
        long.extend(std::iter::repeat_n(b'x', INPUT_LIMIT as usize + 1));
        assert_eq!(message(&mut long.as_slice()), None);
    }
}

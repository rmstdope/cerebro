//! Where the web console asks the supervising fleet view to start, finish or kill an agent: one
//! Unix socket, open only while this view supervises and named in the standby publication. Each
//! connection carries one framed JSON [`Request`] and is answered with one framed JSON [`Reply`],
//! once the view's own loop has acted on it - so the web hears what the keystroke would have
//! said, and every rule the keys obey is obeyed here too, by the same code.

use std::{
    io::Write,
    os::unix::net::{UnixListener, UnixStream},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    time::Duration,
};

use crate::inbox;

/// How long a connection may take to say what it asks.
const ASK_TIMEOUT: Duration = Duration::from_secs(2);

/// How long the view's loop may take to act before the asker is told it did not answer. The
/// loop takes a request every frame, a fifth of a second apart when nothing is pressed.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(5);

/// How many requests may wait for the loop before more are refused.
const QUEUED: usize = 8;

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    /// `s`: start the agent, which also arms it.
    Start,
    /// `f` when no stop flag is set: stop after this pass.
    Finish,
    /// `f` when a stop flag is set: keep going.
    Resume,
    /// `k` on a live session, confirmed by the asker as a kill.
    Kill,
    /// `k` on a standby row, confirmed as a disarm.
    Disarm,
    /// `k` on a starting row, confirmed as stopping the start.
    Stop,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Request {
    pub name: String,
    pub action: Action,
}

/// What the view did: `done` when it acted (or found nothing left to do), and the sentence the
/// keystroke would have put in its header either way.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Reply {
    pub done: bool,
    pub text: String,
}

impl Reply {
    pub fn done(text: impl Into<String>) -> Self {
        Self { done: true, text: text.into() }
    }

    pub fn refused(text: impl Into<String>) -> Self {
        Self { done: false, text: text.into() }
    }
}

/// A request waiting for the loop, and the way back to its asker.
pub struct Asked {
    pub request: Request,
    answer: mpsc::Sender<Reply>,
}

impl Asked {
    pub fn answer(self, reply: Reply) {
        let _ = self.answer.send(reply);
    }
}

pub struct Control {
    path: PathBuf,
    stop: Arc<AtomicBool>,
    asked: mpsc::Receiver<Asked>,
}

impl Control {
    /// Listen at `<temp>/cerebro-<pid>/control.sock`.
    pub fn open() -> std::io::Result<Self> {
        let (listener, path) = inbox::bind("control.sock")?;
        Ok(Self::serve(listener, path))
    }

    #[cfg(test)]
    fn open_at(path: &Path) -> std::io::Result<Self> {
        Ok(Self::serve(UnixListener::bind(path)?, path.to_path_buf()))
    }

    fn serve(listener: UnixListener, path: PathBuf) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let (ask, asked) = mpsc::sync_channel::<Asked>(QUEUED);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                if thread_stop.load(Ordering::SeqCst) {
                    break;
                }
                let Ok(mut stream) = stream else { continue };
                let _ = stream.set_read_timeout(Some(ASK_TIMEOUT));
                let _ = stream.set_write_timeout(Some(ASK_TIMEOUT));
                let Some(bytes) = inbox::message(&mut stream) else { continue };
                if thread_stop.load(Ordering::SeqCst) {
                    break;
                }
                let reply = match serde_json::from_slice::<Request>(&bytes) {
                    Err(error) => Reply::refused(format!("not a request: {error}")),
                    Ok(request) => {
                        let (answer, answered) = mpsc::channel();
                        match ask.try_send(Asked { request, answer }) {
                            Ok(()) => answered.recv_timeout(ANSWER_TIMEOUT).unwrap_or_else(|_| {
                                Reply::refused("The fleet view did not answer in time.")
                            }),
                            Err(mpsc::TrySendError::Full(_)) => {
                                Reply::refused("The fleet view is busy; try again.")
                            }
                            Err(mpsc::TrySendError::Disconnected(_)) => break,
                        }
                    }
                };
                let body = serde_json::to_vec(&reply).expect("a reply serializes");
                let _ = stream.write_all(&inbox::framed(&body));
            }
        });
        Self { path, stop, asked }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Every request waiting for the loop, oldest first. Never blocks.
    pub fn take(&self) -> Vec<Asked> {
        self.asked.try_iter().collect()
    }
}

impl Drop for Control {
    fn drop(&mut self) {
        inbox::close(&self.path, &self.stop);
    }
}

/// Ask the view listening at PATH, and wait for what it did.
pub fn ask(path: &Path, request: &Request) -> std::io::Result<Reply> {
    let mut stream = UnixStream::connect(path)?;
    stream.set_write_timeout(Some(ASK_TIMEOUT))?;
    stream.set_read_timeout(Some(ANSWER_TIMEOUT + ASK_TIMEOUT))?;
    stream.write_all(&inbox::framed(&serde_json::to_vec(request)?))?;
    let bytes = inbox::message(&mut stream)
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::UnexpectedEof, "no reply"))?;
    serde_json::from_slice(&bytes).map_err(std::io::Error::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(name: &str, action: Action) -> Request {
        Request { name: name.into(), action }
    }

    #[test]
    fn a_request_is_answered_with_what_the_loop_did() {
        let dir = tempfile::tempdir().unwrap();
        let control = Control::open_at(&dir.path().join("control.sock")).unwrap();
        let path = control.path().to_path_buf();
        let asker = std::thread::spawn(move || ask(&path, &request("Storm", Action::Finish)).unwrap());

        let asked = loop {
            if let Some(asked) = control.take().pop() {
                break asked;
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        assert_eq!(asked.request, request("Storm", Action::Finish));
        asked.answer(Reply::done("Storm will finish after this pass."));

        assert_eq!(asker.join().unwrap(), Reply::done("Storm will finish after this pass."));
    }

    #[test]
    fn a_request_the_loop_never_takes_is_refused_rather_than_left_waiting() {
        let dir = tempfile::tempdir().unwrap();
        let control = Control::open_at(&dir.path().join("control.sock")).unwrap();
        let path = control.path().to_path_buf();
        let asker = std::thread::spawn(move || ask(&path, &request("Storm", Action::Kill)).unwrap());

        // Taken and dropped unanswered, as a view that stops supervising mid-request does.
        let asked = loop {
            if let Some(asked) = control.take().pop() {
                break asked;
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        drop(asked);

        assert!(!asker.join().unwrap().done);
    }

    #[test]
    fn what_is_not_a_request_is_refused_by_the_socket_itself() {
        let dir = tempfile::tempdir().unwrap();
        let control = Control::open_at(&dir.path().join("control.sock")).unwrap();
        let mut stream = UnixStream::connect(control.path()).unwrap();
        stream.write_all(&inbox::framed(br#"{"name":"Storm","action":"explode"}"#)).unwrap();

        let reply: Reply = serde_json::from_slice(&inbox::message(&mut stream).unwrap()).unwrap();

        assert!(!reply.done);
        assert!(control.take().is_empty());
    }
}

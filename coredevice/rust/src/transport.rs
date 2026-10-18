// SPDX-License-Identifier: GPL-3.0-only
use std::{
    future::Future,
    io,
    pin::Pin,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    task::{Context, Poll, Waker},
};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

pub type Stream = Box<dyn idevice::ReadWrite>;
pub type DialFuture<'a> = Pin<Box<dyn Future<Output = io::Result<Stream>> + Send + 'a>>;
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Purpose {
    PairVerify,
    NegotiatedTunnel { port: u16 },
    LockdownSession,
}
/// The embedding app explicitly selects S3 relay or VPN loopback before connecting.
/// Every call stays on that connector and the same authenticated peer: S3 uses its
/// discovery generation; VPN loopback uses its configured, bound utun interface.
/// Neither connector falls back to another route, usbmux, or a Mac.
pub trait CoreDeviceConnector: Send + Sync {
    fn connect(&self, purpose: Purpose) -> DialFuture<'_>;
}
#[derive(Default)]
pub(crate) struct Gate {
    closed: AtomicBool,
    wakers: Mutex<Vec<Waker>>,
}
impl Gate {
    pub fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        for w in self.wakers.lock().unwrap().drain(..) {
            w.wake();
        }
    }
    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }
    fn check(&self, cx: &Context<'_>) -> io::Result<()> {
        let mut w = self.wakers.lock().unwrap();
        if self.closed.load(Ordering::SeqCst) {
            return Err(io::ErrorKind::ConnectionAborted.into());
        }
        if !w.iter().any(|v| v.will_wake(cx.waker())) {
            if w.len() == 8 {
                w.remove(0);
            }
            w.push(cx.waker().clone());
        }
        Ok(())
    }
}
pub(crate) struct Owner(pub Arc<Gate>);
impl Default for Owner {
    fn default() -> Self {
        Self(Arc::new(Gate::default()))
    }
}
impl Drop for Owner {
    fn drop(&mut self) {
        self.0.close();
    }
}
pub(crate) struct Gated {
    inner: Stream,
    gate: Arc<Gate>,
}
impl std::fmt::Debug for Gated {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("CoreDeviceStream(<redacted>)")
    }
}
impl Gated {
    pub fn new(inner: Stream, gate: Arc<Gate>) -> Self {
        Self { inner, gate }
    }
}
impl AsyncRead for Gated {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if let Err(e) = self.gate.check(cx) {
            return Poll::Ready(Err(e));
        }
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}
impl AsyncWrite for Gated {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        if let Err(e) = self.gate.check(cx) {
            return Poll::Ready(Err(e));
        }
        Pin::new(&mut self.inner).poll_write(cx, buf)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if let Err(e) = self.gate.check(cx) {
            return Poll::Ready(Err(e));
        }
        Pin::new(&mut self.inner).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}
/// Cancellation of a mutating future closes the whole transport generation.
pub(crate) struct OperationGuard(pub Option<Arc<Gate>>);
impl Drop for OperationGuard {
    fn drop(&mut self) {
        if let Some(g) = self.0.take() {
            g.close();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncReadExt;
    #[tokio::test]
    async fn cancellation_wakes_pending_read_without_network() {
        let (stream, _peer) = tokio::io::duplex(64);
        let owner = Owner::default();
        let mut stream = Gated::new(Box::new(stream), owner.0.clone());
        let task = tokio::spawn(async move {
            let mut b = [0];
            stream.read(&mut b).await
        });
        tokio::task::yield_now().await;
        drop(owner);
        assert_eq!(
            tokio::time::timeout(std::time::Duration::from_millis(100), task)
                .await
                .unwrap()
                .unwrap()
                .unwrap_err()
                .kind(),
            io::ErrorKind::ConnectionAborted
        );
    }
}

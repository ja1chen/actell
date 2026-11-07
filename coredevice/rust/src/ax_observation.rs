// SPDX-License-Identifier: GPL-3.0-only
//! One observation budget, with an optional task-selected application fallback.
use crate::{Cause, Error, Stage, ax_diagnostics::Diagnostic, ax_dtx, error};
use std::{future::Future, time::Duration};

#[derive(Clone)]
pub(crate) struct LaunchedApplication {
    pub bundle_id: String,
    pub pid: u32,
    pub executable_url: String,
}
impl LaunchedApplication {
    pub fn receipt(&self) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({"bundle_id": self.bundle_id, "pid": self.pid})).expect("plain launch receipt")
    }
    pub fn matches(&self, pid: u32, executable_url: Option<&str>) -> bool {
        self.pid == pid && !self.executable_url.is_empty() && executable_url == Some(self.executable_url.as_str())
    }
}

#[derive(Debug, PartialEq)]
pub(crate) enum ReadError { Service(Error), AX(ax_dtx::Failure) }
impl From<Error> for ReadError { fn from(value: Error) -> Self { Self::Service(value) } }
impl ReadError {
    pub fn public(self) -> Error {
        match self { Self::Service(e) => e, Self::AX(e) => crate::accessibility_error(e) }
    }
}

pub(crate) trait Reader {
    fn center(&mut self, diagnostic: &mut Diagnostic) -> impl Future<Output = Result<Vec<u8>, ReadError>>;
    /// Revalidate the launched process before opening a fresh AX service stream.
    fn application(&mut self, target: &LaunchedApplication, diagnostic: &mut Diagnostic) -> impl Future<Output = Result<Vec<u8>, ReadError>>;
}

pub(crate) async fn observe(reader: &mut impl Reader, target: Option<&LaunchedApplication>, diagnostic: &mut Diagnostic, budget: Duration) -> Result<Vec<u8>, ReadError> {
    tokio::time::timeout(budget, async {
        match reader.center(diagnostic).await {
            Err(ReadError::AX(ax_dtx::Failure::InitialSelectionUnavailable)) if target.is_some() => {
                let target = target.unwrap();
                diagnostic.begin_pid_fallback(target.pid);
                let data = reader.application(target, diagnostic).await?;
                let mut value: serde_json::Value = serde_json::from_slice(&data)
                    .map_err(|_| error(Stage::AccessibilitySnapshot, Cause::Protocol))?;
                value["application"]["bundleId"] = serde_json::json!(target.bundle_id);
                value["selection"] = serde_json::json!({
                    "method":"explicit-pid", "reason":"center_hit_unavailable",
                    "scope":"requested-application",
                    "initialSelection":{"method":"hit-test", "remoteCode":8}
                });
                serde_json::to_vec(&value).map_err(|_| error(Stage::AccessibilitySnapshot, Cause::Protocol).into())
            }
            result => result,
        }
    }).await.map_err(|_| ReadError::Service(error(Stage::AccessibilitySnapshot, Cause::Timeout)))?
}

#[cfg(test)]
mod tests {
    use super::*;
    struct FakeReader { failure: Option<ax_dtx::Failure>, center_calls: usize, pid_calls: usize, delay: Duration, pid_failure: bool }
    impl Reader for FakeReader {
        async fn center(&mut self, _: &mut Diagnostic) -> Result<Vec<u8>, ReadError> {
            self.center_calls += 1;
            tokio::time::sleep(self.delay).await;
            self.failure.map_or_else(|| Ok(br#"{"application":{"pid":7},"nodes":[],"selection":{"method":"hit-test"}}"#.to_vec()), |e| Err(ReadError::AX(e)))
        }
        async fn application(&mut self, target: &LaunchedApplication, _: &mut Diagnostic) -> Result<Vec<u8>, ReadError> {
            self.pid_calls += 1;
            tokio::time::sleep(self.delay).await;
            if self.pid_failure { return Err(error(Stage::AccessibilitySelection, Cause::SelectionChanged).into()); }
            Ok(serde_json::to_vec(&serde_json::json!({"application":{"pid":target.pid},"nodes":[]})).unwrap())
        }
    }
    fn reader(failure: Option<ax_dtx::Failure>) -> FakeReader {
        FakeReader { failure, center_calls: 0, pid_calls: 0, delay: Duration::ZERO, pid_failure: false }
    }
    fn target() -> LaunchedApplication { LaunchedApplication { bundle_id: "example.fixture".into(), pid: 7, executable_url: "PRIVATE_EXECUTABLE_PATH".into() } }
    #[tokio::test]
    async fn initial_miss_uses_one_explicit_read_and_preserves_scope() {
        let mut reader = reader(Some(ax_dtx::Failure::InitialSelectionUnavailable));
        let data = observe(&mut reader, Some(&target()), &mut Diagnostic::new("hit_test"), Duration::from_secs(1)).await.unwrap();
        let value: serde_json::Value = serde_json::from_slice(&data).unwrap();
        assert_eq!((reader.center_calls, reader.pid_calls), (1, 1));
        assert_eq!(value["application"]["pid"], 7);
        assert!(value["selection"].get("foregroundAppConfirmed").is_none());
        assert_eq!(value["selection"]["scope"], "requested-application");
        assert!(!String::from_utf8(data).unwrap().contains("PRIVATE_"));
    }
    #[tokio::test]
    async fn success_verification_failures_and_missing_targets_never_fallback() {
        for failure in [None, Some(ax_dtx::Failure::PointUnavailable), Some(ax_dtx::Failure::SelectionChanged), Some(ax_dtx::Failure::Timeout(ax_dtx::Phase::Selection)), Some(ax_dtx::Failure::Mismatch)] {
            let mut reader = reader(failure);
            let _ = observe(&mut reader, Some(&target()), &mut Diagnostic::new("hit_test"), Duration::from_secs(1)).await;
            assert_eq!((reader.center_calls, reader.pid_calls), (1, 0));
        }
        let mut reader = reader(Some(ax_dtx::Failure::InitialSelectionUnavailable));
        assert!(observe(&mut reader, None, &mut Diagnostic::new("hit_test"), Duration::from_secs(1)).await.is_err());
        assert_eq!(reader.pid_calls, 0);
    }
    #[tokio::test(start_paused = true)]
    async fn fallback_failure_is_not_retried_and_both_reads_share_a_deadline() {
        let mut failed = reader(Some(ax_dtx::Failure::InitialSelectionUnavailable)); failed.pid_failure = true;
        assert!(observe(&mut failed, Some(&target()), &mut Diagnostic::new("hit_test"), Duration::from_secs(1)).await.is_err());
        assert_eq!((failed.center_calls, failed.pid_calls), (1, 1));
        let mut slow = reader(Some(ax_dtx::Failure::InitialSelectionUnavailable)); slow.delay = Duration::from_millis(40);
        assert_eq!(observe(&mut slow, Some(&target()), &mut Diagnostic::new("hit_test"), Duration::from_millis(60)).await,
            Err(ReadError::Service(error(Stage::AccessibilitySnapshot, Cause::Timeout))));
        assert_eq!((slow.center_calls, slow.pid_calls), (1, 1));
    }
    #[test]
    fn target_requires_matching_process_identity_and_receipt_excludes_private_fields() {
        let target = target();
        assert!(target.matches(7, Some("PRIVATE_EXECUTABLE_PATH")));
        assert!(!target.matches(8, Some("PRIVATE_EXECUTABLE_PATH")));
        assert!(!target.matches(7, Some("OTHER_PATH")));
        assert!(!target.matches(7, None));
        let receipt: serde_json::Value = serde_json::from_slice(&target.receipt()).unwrap();
        assert_eq!(receipt, serde_json::json!({"bundle_id":"example.fixture","pid":7}));
    }
}

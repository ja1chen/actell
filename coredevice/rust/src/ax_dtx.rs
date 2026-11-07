// SPDX-License-Identifier: GPL-3.0-only
//! Bounded DTX control session for the raw accessibility service.
//! This module does not start XCTest or create a device connection itself.
use std::{collections::{HashMap, VecDeque}, time::Duration};
use plist::{Dictionary, Uid, Value};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

const MAX_MESSAGE: usize = 20 * 1024 * 1024;
const MAX_INPUT: usize = 40 * 1024 * 1024;
const MAX_FRAGMENTS: u16 = 512;
const MAX_QUEUED: usize = 128;
const STEP_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Phase { Handshake, Version, Subscription, Selection, Root, Snapshot, Cleanup }
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum SemanticIssue { Ack, PacketArgument, PacketHeader, PacketType, PacketLength, PacketArchive, ArchiveInvalid, RemoteRefused }
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Failure { Handshake, Version, UnsupportedVersion, Subscription, Selection, SelectionChanged, PointUnavailable, InitialSelectionUnavailable, Root, Snapshot, Mismatch, Limit, Protocol, Timeout(Phase), Semantic(Phase, SemanticIssue), SemanticAck, PacketArgument, PacketHeader, PacketType, PacketLength, PacketArchive, ArchiveInvalid, RemoteRefused }

#[derive(Debug, Eq, PartialEq)]
pub(crate) struct ProbeReport {
    pub api_version: u64,
    pub subscription_stop_confirmed: bool,
    pub local_write_shutdown_completed: bool,
}

fn dict(pairs: impl IntoIterator<Item = (&'static str, Value)>) -> Value {
    let mut map = Dictionary::new();
    for (key, value) in pairs { map.insert(key.into(), value); }
    Value::Dictionary(map)
}
fn uid(index: usize) -> Value { Value::Uid(Uid::new(index as u64)) }

/// Foundation keyed-archive encoder for DTX control values. It never instantiates
/// Foundation objects and the only classes emitted here are collections.
fn archive(value: &Value) -> Result<Vec<u8>, Failure> {
    fn encode(value: &Value, objects: &mut Vec<Value>, depth: usize) -> Result<Value, Failure> {
        if depth > 64 || objects.len() > 4096 { return Err(Failure::Protocol); }
        let index = objects.len();
        objects.push(Value::String("$pending".into()));
        let entry = match value {
            Value::Dictionary(map) => {
                let mut keys = Vec::with_capacity(map.len());
                let mut values = Vec::with_capacity(map.len());
                for (key, value) in map {
                    keys.push(encode(&Value::String(key.clone()), objects, depth + 1)?);
                    values.push(encode(value, objects, depth + 1)?);
                }
                let class = objects.len();
                objects.push(dict([
                    ("$classname", Value::String("NSDictionary".into())),
                    ("$classes", Value::Array(vec![Value::String("NSDictionary".into()), Value::String("NSObject".into())])),
                ]));
                dict([("NS.keys", Value::Array(keys)), ("NS.objects", Value::Array(values)), ("$class", uid(class))])
            }
            Value::Array(values) => {
                let mut elements = Vec::with_capacity(values.len());
                for value in values { elements.push(encode(value, objects, depth + 1)?); }
                let class = objects.len();
                objects.push(dict([
                    ("$classname", Value::String("NSArray".into())),
                    ("$classes", Value::Array(vec![Value::String("NSArray".into()), Value::String("NSObject".into())])),
                ]));
                dict([("NS.objects", Value::Array(elements)), ("$class", uid(class))])
            }
            Value::String(_) | Value::Integer(_) | Value::Boolean(_) | Value::Data(_) | Value::Real(_) => value.clone(),
            _ => return Err(Failure::Protocol),
        };
        objects[index] = entry;
        Ok(uid(index))
    }
    let mut objects = vec![Value::String("$null".into())];
    let root = encode(value, &mut objects, 0)?;
    let archive = dict([
        ("$version", Value::Integer(100000.into())),
        ("$archiver", Value::String("NSKeyedArchiver".into())),
        ("$top", dict([("root", root)])),
        ("$objects", Value::Array(objects)),
    ]);
    let mut bytes = Vec::new();
    archive.to_writer_binary(&mut bytes).map_err(|_| Failure::Protocol)?;
    Ok(bytes)
}

/// Only scalar control values are accepted here; AX archives have their own
/// bounded decoder. In particular, do not deserialize private Objective-C types.
fn unarchive_scalar(bytes: &[u8]) -> Result<Value, Failure> {
    match crate::ax_archive::decode(bytes).map_err(|_| Failure::Protocol)? {
        crate::ax_archive::AxValue::String(v) => Ok(Value::String(v)),
        crate::ax_archive::AxValue::Integer(v) => Ok(Value::Integer(v)),
        crate::ax_archive::AxValue::Bool(v) => Ok(Value::Boolean(v)),
        crate::ax_archive::AxValue::Data(v) => Ok(Value::Data(v)),
        _ => Err(Failure::Protocol),
    }
}

fn aux(values: &[Value]) -> Result<Vec<u8>, Failure> {
    if values.is_empty() { return Ok(Vec::new()); }
    let mut body = Vec::new();
    for value in values {
        let data = archive(value)?;
        body.extend_from_slice(&10u32.to_le_bytes());
        body.extend_from_slice(&2u32.to_le_bytes());
        body.extend_from_slice(&(data.len() as u32).to_le_bytes());
        body.extend_from_slice(&data);
    }
    let mut output = Vec::new();
    output.extend_from_slice(&0x1f0u32.to_le_bytes());
    output.extend_from_slice(&0u32.to_le_bytes());
    output.extend_from_slice(&(body.len() as u64).to_le_bytes());
    output.extend_from_slice(&body);
    Ok(output)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Header { id: u32, conversation: u32, channel: i32, expects_reply: bool }
struct Message { header: Header, kind: u8, aux: Vec<u8>, data: Vec<u8> }
struct Fragments { header: Header, count: u16, total: usize, size: usize, parts: Vec<Option<Vec<u8>>> }

fn u16le(b: &[u8]) -> u16 { u16::from_le_bytes([b[0], b[1]]) }
fn u32le(b: &[u8]) -> u32 { u32::from_le_bytes([b[0], b[1], b[2], b[3]]) }

struct Dtx<S> {
    io: S,
    next_id: u32,
    fragments: HashMap<u32, Fragments>,
    reserved: usize,
    received: usize,
    notifications: usize,
    packets: VecDeque<Vec<u8>>,
}
impl<S: AsyncRead + AsyncWrite + Unpin> Dtx<S> {
    fn new(io: S) -> Self {
        Self { io, next_id: 1, fragments: HashMap::new(), reserved: 0, received: 0, notifications: 0, packets: VecDeque::new() }
    }
    async fn send(&mut self, h: Header, kind: u8, args: &[u8], data: &[u8]) -> Result<(), Failure> {
        let size = 16usize.checked_add(args.len()).and_then(|n| n.checked_add(data.len())).ok_or(Failure::Protocol)?;
        if size > MAX_MESSAGE { return Err(Failure::Protocol); }
        let mut out = Vec::with_capacity(32 + size);
        out.extend_from_slice(&0x1f3d5b79u32.to_le_bytes());
        out.extend_from_slice(&32u32.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&(size as u32).to_le_bytes());
        out.extend_from_slice(&h.id.to_le_bytes());
        out.extend_from_slice(&h.conversation.to_le_bytes());
        out.extend_from_slice(&h.channel.to_le_bytes());
        out.extend_from_slice(&(h.expects_reply as u32).to_le_bytes());
        out.extend_from_slice(&[kind, 0, 0, 0]);
        out.extend_from_slice(&(args.len() as u32).to_le_bytes());
        out.extend_from_slice(&((args.len() + data.len()) as u32).to_le_bytes());
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(args); out.extend_from_slice(data);
        self.io.write_all(&out).await.map_err(|_| Failure::Protocol)?;
        self.io.flush().await.map_err(|_| Failure::Protocol)
    }
    async fn send_call(&mut self, name: &str, args: &[Value], expects_reply: bool) -> Result<u32, Failure> {
        let id = self.next_id;
        self.next_id = self.next_id.checked_add(1).ok_or(Failure::Protocol)?;
        self.send(Header { id, conversation: 0, channel: 0, expects_reply }, 2, &aux(args)?, &archive(&Value::String(name.into()))?).await?;
        Ok(id)
    }
    async fn reply(&mut self, h: Header, value: Option<Value>) -> Result<(), Failure> {
        if !h.expects_reply { return Ok(()); }
        let data = value.as_ref().map(archive).transpose()?.unwrap_or_default();
        self.send(Header { conversation: h.conversation.checked_add(1).ok_or(Failure::Protocol)?, channel: -h.channel, expects_reply: false, ..h },
            if data.is_empty() { 0 } else { 3 }, &[], &data).await
    }
    async fn receive(&mut self) -> Result<Message, Failure> {
        loop {
            let mut b = [0u8; 32]; self.io.read_exact(&mut b).await.map_err(|_| Failure::Protocol)?;
            if u32le(&b[0..4]) != 0x1f3d5b79 || u32le(&b[4..8]) != 32 { return Err(Failure::Protocol); }
            let index = u16le(&b[8..10]); let count = u16le(&b[10..12]); let size = u32le(&b[12..16]) as usize;
            let flags = u32le(&b[28..32]);
            if count == 0 || count > MAX_FRAGMENTS || index >= count || flags > 1 || size > MAX_MESSAGE || size == 0 { return Err(Failure::Protocol); }
            let header = Header { id: u32le(&b[16..20]), conversation: u32le(&b[20..24]), channel: i32::from_le_bytes(b[24..28].try_into().unwrap()), expects_reply: flags == 1 };
            if count > 1 && index == 0 {
                if self.fragments.contains_key(&header.id) || self.fragments.len() >= MAX_QUEUED || self.reserved.checked_add(size).is_none_or(|v| v > MAX_INPUT) { return Err(Failure::Protocol); }
                self.reserved += size;
                self.fragments.insert(header.id, Fragments { header, count, total: size, size: 0, parts: (0..count-1).map(|_| None).collect() });
                continue;
            }
            self.received = self.received.checked_add(size).ok_or(Failure::Protocol)?;
            if self.received > MAX_INPUT { return Err(Failure::Protocol); }
            let mut body = vec![0; size]; self.io.read_exact(&mut body).await.map_err(|_| Failure::Protocol)?;
            let (h, bytes) = if count == 1 {
                if index != 0 { return Err(Failure::Protocol); }
                (header, body)
            } else {
                let pending = self.fragments.get_mut(&header.id).ok_or(Failure::Protocol)?;
                if pending.header != header || pending.count != count || pending.parts[(index - 1) as usize].is_some() || pending.size.checked_add(size).is_none_or(|n| n > pending.total) { return Err(Failure::Protocol); }
                pending.size += size; pending.parts[(index - 1) as usize] = Some(body);
                if pending.parts.iter().any(Option::is_none) { continue; }
                let pending = self.fragments.remove(&header.id).ok_or(Failure::Protocol)?;
                self.reserved -= pending.total;
                if pending.size != pending.total { return Err(Failure::Protocol); }
                let mut joined = Vec::with_capacity(pending.total);
                for part in pending.parts { joined.extend_from_slice(&part.ok_or(Failure::Protocol)?); }
                (pending.header, joined)
            };
            if bytes.len() < 16 { return Err(Failure::Protocol); }
            let aux_size = u32le(&bytes[4..8]) as usize;
            let total = u32le(&bytes[8..12]) as usize;
            if total != bytes.len() - 16 || aux_size > total || bytes[1..4] != [0,0,0] || u32le(&bytes[12..16]) != 0 { return Err(Failure::Protocol); }
            return Ok(Message { header: h, kind: bytes[0], aux: bytes[16..16+aux_size].to_vec(), data: bytes[16+aux_size..].to_vec() });
        }
    }
    async fn incoming(&mut self, msg: &Message) -> Result<bool, Failure> {
        if msg.header.conversation != 0 { return Ok(false); }
        self.notifications += 1;
        if self.notifications > MAX_QUEUED { return Err(Failure::Protocol); }
        if msg.header.channel != 0 || msg.kind != 2 {
            return if msg.header.expects_reply { Err(Failure::Protocol) } else { Ok(false) };
        }
        let selector = unarchive_scalar(&msg.data)?;
        match selector.as_string().ok_or(Failure::Protocol)? {
            "hostAPIVersion" => { self.reply(msg.header, Some(Value::Integer(7.into()))).await?; Ok(false) }
            "_notifyOfPublishedCapabilities:" => { self.reply(msg.header, None).await?; Ok(true) }
            "processDataFromRemoteDevice:" => {
                let packet = decode_packet_argument(&msg.aux)?;
                if self.packets.len() >= MAX_QUEUED { return Err(Failure::Limit); }
                self.packets.push_back(packet);
                self.reply(msg.header, None).await?;
                Ok(false)
            }
            // Ignore bounded one-way notifications, but do not invent a reply
            // for an unknown remote invocation that requires one.
            _ => if msg.header.expects_reply { Err(Failure::Protocol) } else { Ok(false) },
        }
    }
    async fn wait_handshake(&mut self) -> Result<(), Failure> {
        loop { let msg = self.receive().await?; if self.incoming(&msg).await? { return Ok(()); } }
    }
    async fn call(&mut self, name: &str, args: &[Value]) -> Result<Option<Value>, Failure> {
        let id = self.send_call(name, args, true).await?;
        loop {
            let msg = self.receive().await?;
            if msg.header.conversation == 0 { self.incoming(&msg).await?; continue; }
            if msg.header.id != id || msg.header.conversation != 1 || msg.header.channel != 0 || !msg.aux.is_empty() { return Err(Failure::Protocol); }
            return match msg.kind {
                0 if msg.data.is_empty() => Ok(None),
                3 => Ok(Some(unarchive_scalar(&msg.data)?)),
                _ => Err(Failure::Protocol),
            };
        }
    }
    async fn semantic(&mut self, request_type: u64, request: Vec<u8>, token: Option<&crate::ax_archive::Token>, diagnostic: Option<&mut crate::ax_diagnostics::Diagnostic>) -> Result<crate::ax_archive::AxValue, Failure> {
        let phase = match request_type { 1 => Phase::Root, 6 => Phase::Selection, _ => Phase::Snapshot };
        self.semantic_inner(request_type, request, token, diagnostic).await.map_err(|e| {
            let issue = match e {
                Failure::SemanticAck => SemanticIssue::Ack, Failure::PacketArgument => SemanticIssue::PacketArgument,
                Failure::PacketHeader => SemanticIssue::PacketHeader, Failure::PacketType => SemanticIssue::PacketType,
                Failure::PacketLength => SemanticIssue::PacketLength, Failure::PacketArchive => SemanticIssue::PacketArchive,
                Failure::ArchiveInvalid => SemanticIssue::ArchiveInvalid, Failure::RemoteRefused => SemanticIssue::RemoteRefused,
                _ => return e,
            };
            Failure::Semantic(phase, issue)
        })
    }
    async fn semantic_inner(&mut self, request_type: u64, request: Vec<u8>, token: Option<&crate::ax_archive::Token>, mut diagnostic: Option<&mut crate::ax_diagnostics::Diagnostic>) -> Result<crate::ax_archive::AxValue, Failure> {
        use crate::ax_archive::{self, AxValue, Token};
        self.call("processDataFromHost:", &[Value::Data(request)]).await.map_err(|_| Failure::SemanticAck)?;
        let mut discarded = 0usize;
        loop {
            while let Some(packet) = self.packets.pop_front() {
                let reply = ax_archive::decode(&packet).map_err(|e| match e { ax_archive::ArchiveError::Limit => Failure::Limit, _ => Failure::ArchiveInvalid })?;
                if reply.field("associatedRequestType").and_then(AxValue::uint) != Some(request_type) {
                    discarded += 1; if discarded > 256 { return Err(Failure::Limit); } continue;
                }
                if let Some(err) = reply.field("error") {
                    if err != &AxValue::Null && err.uint() != Some(0) {
                        let has_result = reply.field("resultData").is_some_and(|value| value != &AxValue::Null);
                        if let Some(trace) = diagnostic.as_deref_mut() {
                            trace.remote_error(err, has_result);
                        }
                        if request_type == 6 && matches!(err, AxValue::Integer(_)) && err.uint() == Some(8) && !has_result {
                            return Err(Failure::PointUnavailable);
                        }
                        return Err(Failure::RemoteRefused);
                    }
                }
                if let Some(token) = token {
                    let associated = reply.field("associatedTranslationObject").ok_or(Failure::Mismatch).and_then(|v| Token::from_value(v).map_err(|_| Failure::Mismatch))?;
                    if reply.field("attribute").and_then(AxValue::uint) != Some(52) || associated.pid != token.pid || associated.object_id != token.object_id { return Err(Failure::Mismatch); }
                }
                let result = reply.field("resultData").cloned().unwrap_or(AxValue::Null);
                if result == AxValue::Null { return Err(match request_type { 1 => Failure::Root, 6 => Failure::Selection, _ => Failure::Snapshot }); }
                return Ok(result);
            }
            let incoming = self.receive().await?;
            if incoming.header.conversation != 0 { return Err(Failure::Protocol); }
            self.incoming(&incoming).await?;
        }
    }
}

fn decode_packet_argument(bytes: &[u8]) -> Result<Vec<u8>, Failure> {
    if bytes.len() < 28 { return Err(Failure::PacketArgument); }
    if u32le(&bytes[..4]) & 0xff != 0xf0 || u32le(&bytes[4..8]) != 0 { return Err(Failure::PacketHeader); }
    let len = u64::from_le_bytes(bytes[8..16].try_into().unwrap());
    if usize::try_from(len).ok() != Some(bytes.len() - 16) { return Err(Failure::PacketLength); }
    if u32le(&bytes[16..20]) != 10 || u32le(&bytes[20..24]) & 0xff != 2 { return Err(Failure::PacketType); }
    let n = u32le(&bytes[24..28]) as usize;
    if n != bytes.len() - 28 { return Err(Failure::PacketLength); }
    match crate::ax_archive::decode(&bytes[28..]).map_err(|_| Failure::PacketArchive)? {
        crate::ax_archive::AxValue::Data(data) if data.len() <= MAX_MESSAGE => Ok(data),
        _ => Err(Failure::PacketArchive),
    }
}

async fn deadline<T>(phase: Phase, work: impl std::future::Future<Output = Result<T, Failure>>) -> Result<T, Failure> {
    tokio::time::timeout(STEP_TIMEOUT, work).await.map_err(|_| Failure::Timeout(phase))?
}

/// Opens no new VPN/pairing; caller passes the already-connected service stream.
/// The resulting report distinguishes confirmed stop from transport shutdown.
pub(crate) async fn probe<S: AsyncRead + AsyncWrite + Unpin>(stream: S) -> Result<ProbeReport, Failure> {
    let mut dtx = Dtx::new(stream);
    let mut diagnostic = crate::ax_diagnostics::Diagnostic::new("probe");
    let version = negotiate(&mut dtx, &mut diagnostic).await?;
    Ok(cleanup(&mut dtx, version).await)
}

async fn negotiate<S: AsyncRead + AsyncWrite + Unpin>(dtx: &mut Dtx<S>, diagnostic: &mut crate::ax_diagnostics::Diagnostic) -> Result<u64, Failure> {
    let caps = dict([
        ("com.apple.private.DTXBlockCompression", Value::Integer(0.into())),
        ("com.apple.private.DTXConnection", Value::Integer(1.into())),
    ]);
    diagnostic.enter("handshake", None);
    deadline(Phase::Handshake, async {
        dtx.send_call("_notifyOfPublishedCapabilities:", &[caps], false).await?;
        dtx.wait_handshake().await
    }).await.map_err(|e| if matches!(e, Failure::Timeout(_)) { e } else { Failure::Handshake })?;
    diagnostic.enter("version", None);
    let version = deadline(Phase::Version, dtx.call("deviceAPIVersion", &[])).await
        .map_err(|e| if matches!(e, Failure::Timeout(_)) { e } else { Failure::Version })?
        .and_then(|v| v.as_unsigned_integer()).ok_or(Failure::Version)?;
    if version != 26 { return Err(Failure::UnsupportedVersion); }
    diagnostic.enter("subscription", None);
    deadline(Phase::Subscription, dtx.call("clientNeedsAccessibility:", &[Value::Boolean(true)])).await
        .map_err(|e| if matches!(e, Failure::Timeout(_)) { e } else { Failure::Subscription })?;
    diagnostic.subscribed();
    Ok(version)
}
async fn cleanup<S: AsyncRead + AsyncWrite + Unpin>(dtx: &mut Dtx<S>, version: u64) -> ProbeReport {
    // Failure or timeout here is reported separately: sending a stop request is
    // not proof the daemon acknowledged it. The stream is always dropped.
    let stopped = deadline(Phase::Cleanup, dtx.call("clientNeedsAccessibility:", &[Value::Boolean(false)])).await.is_ok();
    let closed = deadline(Phase::Cleanup, async { dtx.io.shutdown().await.map_err(|_| Failure::Protocol) }).await.is_ok();
    ProbeReport { api_version: version, subscription_stop_confirmed: stopped, local_write_shutdown_completed: closed }
}

/// A session is never reused after a failed or timed-out semantic request.
/// Root identity is acquired twice to catch a target process/root change.
#[derive(Clone, Copy)]
pub(crate) enum Selection { ExplicitPid(u64), HitPoint { x: f64, y: f64 } }
pub(crate) async fn snapshot<S: AsyncRead + AsyncWrite + Unpin>(stream: S, selection: Selection, diagnostic: &mut crate::ax_diagnostics::Diagnostic) -> Result<Vec<u8>, Failure> {
    use crate::ax_archive::{self, Token};
    let started = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(|_| Failure::Protocol)?.as_millis();
    let mut dtx = Dtx::new(stream);
    let version = negotiate(&mut dtx, diagnostic).await?;
    let result = async {
        let pid = match selection {
            Selection::ExplicitPid(pid) => pid,
            Selection::HitPoint { x, y } => {
                diagnostic.enter("selection_initial", Some(6));
                let selected = deadline(Phase::Selection, dtx.semantic(6, ax_archive::hit_request(x, y).map_err(|_| Failure::Selection)?, None, Some(diagnostic))).await
                    .map_err(|e| if e == Failure::PointUnavailable { Failure::InitialSelectionUnavailable } else { e })?;
                Token::from_value(&selected).map_err(|_| Failure::Selection)?.pid
            }
        };
        diagnostic.pid("target_pid", pid);
        diagnostic.enter("root_initial", Some(1));
        let root_request = ax_archive::request(pid, None).map_err(|_| Failure::Root)?;
        let root = deadline(Phase::Root, dtx.semantic(1, root_request, None, Some(diagnostic))).await.map_err(|e| if e == Failure::Protocol { Failure::Root } else { e })?;
        let token = Token::from_value(&root).map_err(|_| Failure::Root)?;
        if token.pid != pid || !token.is_app { return Err(Failure::Mismatch); }
        diagnostic.enter("snapshot", Some(2));
        let req = ax_archive::request(pid, Some(&token)).map_err(|_| Failure::Snapshot)?;
        let tree = deadline(Phase::Snapshot, dtx.semantic(2, req, Some(&token), Some(diagnostic))).await.map_err(|e| if e == Failure::Protocol { Failure::Snapshot } else { e })?;
        diagnostic.enter("root_verify", Some(1));
        let again = deadline(Phase::Root, dtx.semantic(1, ax_archive::request(pid, None).map_err(|_| Failure::Root)?, None, Some(diagnostic))).await?;
        let again = Token::from_value(&again).map_err(|_| Failure::Root)?;
        diagnostic.pid("observed_pid", again.pid);
        if again.pid != token.pid || again.object_id != token.object_id || !again.is_app { return Err(Failure::SelectionChanged); }
        if let Selection::HitPoint { x, y } = selection {
            diagnostic.enter("selection_verify", Some(6));
            let selected = deadline(Phase::Selection, dtx.semantic(6, ax_archive::hit_request(x, y).map_err(|_| Failure::Selection)?, None, Some(diagnostic))).await?;
            let selected_pid = Token::from_value(&selected).map_err(|_| Failure::Selection)?.pid;
            diagnostic.pid("observed_pid", selected_pid);
            if selected_pid != pid { return Err(Failure::SelectionChanged); }
        }
        diagnostic.enter("normalize", None);
        let ended = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(|_| Failure::Protocol)?.as_millis();
        let mut normalized = crate::ax_snapshot::normalize(&tree, &token, started, ended)?;
        if let Selection::HitPoint { x, y } = selection {
            normalized["selection"] = serde_json::json!({"method":"hit-test", "point":{"x":x,"y":y}, "displayId":0,
                "scope":"process-at-point"});
        }
        Ok(normalized)
    }.await;
    // A timed-out or inconsistent semantic stream is dropped immediately; a
    // subsequent request must use a fresh service connection.
    match result {
        Ok(mut data) => {
            let report = cleanup(&mut dtx, version).await;
            data["cleanup"] = serde_json::json!({"subscriptionStopConfirmed":report.subscription_stop_confirmed, "localWriteShutdownCompleted":report.local_write_shutdown_completed});
            serde_json::to_vec(&data).map_err(|_| Failure::Protocol)
        }
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn selector(msg: &Message) -> String { unarchive_scalar(&msg.data).unwrap().as_string().unwrap().to_owned() }
    async fn send_dispatch<S: AsyncRead + AsyncWrite + Unpin>(server: &mut Dtx<S>, id: u32, name: &str, args: &[Value], reply: bool) {
        server.send(Header { id, conversation: 0, channel: 0, expects_reply: reply }, 2, &aux(args).unwrap(), &archive(&Value::String(name.into())).unwrap()).await.unwrap();
    }
    #[tokio::test]
    async fn remote_refusal_preserves_initial_and_verification_selection_diagnostics() {
        for (failure_at, integer_error, has_result) in [(0, false, false), (4, false, false), (0, true, false), (4, true, false), (0, true, true), (4, true, true)] {
            let (client, server) = tokio::io::duplex(64 * 1024);
            let remote = tokio::spawn(async move {
                let mut server = Dtx::new(server);
                let _hello = server.receive().await.unwrap();
                send_dispatch(&mut server, 90, "_notifyOfPublishedCapabilities:", &[], false).await;
                let api = server.receive().await.unwrap(); server.reply(api.header, Some(Value::Integer(26.into()))).await.unwrap();
                let subscribe = server.receive().await.unwrap(); server.reply(subscribe.header, None).await.unwrap();
                let token = dict([("pid", Value::Integer(7.into())), ("objectID", Value::Integer(9.into())), ("isApplicationElement", Value::Boolean(true))]);
                for (index, kind) in [6u64, 1, 2, 1, 6].into_iter().enumerate().take(failure_at + 1) {
                    let call = server.receive().await.unwrap(); assert_eq!(selector(&call), "processDataFromHost:");
                    server.reply(call.header, None).await.unwrap();
                    let mut reply = Dictionary::new();
                    reply.insert("associatedRequestType".into(), Value::Integer(kind.into()));
                    if index == failure_at {
                        reply.insert("error".into(), if integer_error { Value::Integer(8.into()) } else { dict([("NSCode", Value::Integer((-25204i64).into())),
                            ("NSDomain", Value::String("AXErrorDomain".into())),
                            ("NSLocalizedDescription", Value::String("PRIVATE_REMOTE_TEXT".into()))]) });
                        if has_result { reply.insert("resultData".into(), token.clone()); }
                    } else if kind == 2 {
                        reply.insert("attribute".into(), Value::Integer(52.into()));
                        reply.insert("associatedTranslationObject".into(), token.clone());
                        reply.insert("resultData".into(), Value::String("PRIVATE_TREE_TEXT".into()));
                    } else { reply.insert("resultData".into(), token.clone()); }
                    send_dispatch(&mut server, 100 + index as u32, "processDataFromRemoteDevice:", &[Value::Data(archive(&Value::Dictionary(reply)).unwrap())], true).await;
                    assert_eq!(server.receive().await.unwrap().kind, 0);
                }
            });
            let mut diagnostic = crate::ax_diagnostics::Diagnostic::new("hit_test");
            let result = snapshot(client, Selection::HitPoint { x: 100.0, y: 200.0 }, &mut diagnostic).await;
            let expected = if integer_error && !has_result {
                if failure_at == 0 { Failure::InitialSelectionUnavailable } else { Failure::PointUnavailable }
            } else { Failure::Semantic(Phase::Selection, SemanticIssue::RemoteRefused) };
            assert_eq!(result.unwrap_err(), expected);
            remote.await.unwrap();
            let data = diagnostic.payload().unwrap();
            let value: serde_json::Value = serde_json::from_slice(&data).unwrap();
            assert_eq!(value["phase"], if failure_at == 0 { "selection_initial" } else { "selection_verify" }); assert_eq!(value["request_type"], 6);
            assert_eq!(value["remote_code"], if integer_error { "8" } else { "-25204" });
            if !integer_error { assert_eq!(value["remote_domain"], "AXErrorDomain"); }
            assert_eq!(value["has_result"], has_result);
            assert!(value.get("subscription_ack_ms").is_some());
            assert!(!String::from_utf8(data).unwrap().contains("PRIVATE_"));
        }
    }
    #[test]
    fn control_archives_preserve_types() {
        for value in [Value::String("hostAPIVersion".into()), Value::Integer(7.into()), Value::Boolean(false), Value::Data(vec![1,2,3])] {
            assert_eq!(unarchive_scalar(&archive(&value).unwrap()).unwrap(), value);
        }
    }
    #[tokio::test]
    async fn short_and_oversized_frames_are_rejected() {
        for size in [1u32, (MAX_MESSAGE as u32) + 1] {
            let (client, mut server) = tokio::io::duplex(256);
            let mut h = vec![0;32]; h[0..4].copy_from_slice(&0x1f3d5b79u32.to_le_bytes());
            h[4..8].copy_from_slice(&32u32.to_le_bytes()); h[10..12].copy_from_slice(&1u16.to_le_bytes());
            h[12..16].copy_from_slice(&size.to_le_bytes()); server.write_all(&h).await.unwrap();
            if size == 1 { server.write_all(&[0]).await.unwrap(); }
            assert!(Dtx::new(client).receive().await.is_err());
        }
    }
    #[tokio::test]
    async fn negotiation_handles_host_callback_and_confirms_stop() {
        let (client, server) = tokio::io::duplex(64 * 1024);
        let remote = tokio::spawn(async move {
            let mut server = Dtx::new(server);
            let hello = server.receive().await.unwrap();
            assert_eq!(selector(&hello), "_notifyOfPublishedCapabilities:");
            send_dispatch(&mut server, 90, "hostAPIVersion", &[], true).await;
            let response = server.receive().await.unwrap();
            assert_eq!(response.header.id, 90); assert_eq!(response.header.conversation, 1);
            assert_eq!(unarchive_scalar(&response.data).unwrap().as_unsigned_integer(), Some(7));
            send_dispatch(&mut server, 91, "_notifyOfPublishedCapabilities:", &[], false).await;
            let api = server.receive().await.unwrap(); assert_eq!(selector(&api), "deviceAPIVersion");
            server.reply(api.header, Some(Value::Integer(26.into()))).await.unwrap();
            for expected in [true, false] {
                let request = server.receive().await.unwrap(); assert_eq!(selector(&request), "clientNeedsAccessibility:");
                assert_eq!(unarchive_scalar(&request.aux[28..]).unwrap(), Value::Boolean(expected));
                server.reply(request.header, None).await.unwrap();
            }
        });
        let report = probe(client).await.unwrap();
        assert_eq!(report, ProbeReport { api_version: 26, subscription_stop_confirmed: true, local_write_shutdown_completed: true });
        remote.await.unwrap();
    }
    #[tokio::test]
    async fn missing_stop_ack_is_not_reported_as_confirmed() {
        let (client, server) = tokio::io::duplex(64 * 1024);
        let remote = tokio::spawn(async move {
            let mut server = Dtx::new(server);
            let _hello = server.receive().await.unwrap();
            send_dispatch(&mut server, 90, "_notifyOfPublishedCapabilities:", &[], false).await;
            let api = server.receive().await.unwrap(); server.reply(api.header, Some(Value::Integer(26.into()))).await.unwrap();
            let subscribe = server.receive().await.unwrap(); server.reply(subscribe.header, None).await.unwrap();
            let stop = server.receive().await.unwrap(); assert_eq!(selector(&stop), "clientNeedsAccessibility:");
            // The peer closes after seeing stop, without an acknowledgement.
        });
        let report = probe(client).await.unwrap();
        assert!(!report.subscription_stop_confirmed);
        remote.await.unwrap();
    }
    #[tokio::test]
    async fn ack_is_not_semantic_response_and_other_type_is_discarded() {
        let (client, server) = tokio::io::duplex(64 * 1024);
        let mut remote = Dtx::new(server);
        let mut task = tokio::spawn(async move { Dtx::new(client).semantic(1, vec![1,2,3], None, None).await });
        let call = remote.receive().await.unwrap(); assert_eq!(selector(&call), "processDataFromHost:");
        remote.reply(call.header, None).await.unwrap();
        assert!(tokio::time::timeout(Duration::from_millis(25), &mut task).await.is_err());
        for (id, kind) in [(101, 5u64), (102, 1u64)] {
            let envelope = dict([("associatedRequestType", Value::Integer(kind.into())), ("resultData", Value::String("fixture".into()))]);
            send_dispatch(&mut remote, id, "processDataFromRemoteDevice:", &[Value::Data(archive(&envelope).unwrap())], true).await;
            let ack = remote.receive().await.unwrap(); assert_eq!(ack.header.id, id); assert_eq!(ack.kind, 0);
        }
        assert_eq!(task.await.unwrap().unwrap(), crate::ax_archive::AxValue::String("fixture".into()));
    }
    #[tokio::test]
    async fn bad_or_incomplete_fragments_fail_closed() {
        let (client, mut server) = tokio::io::duplex(256);
        let mut h = vec![0; 32]; h[0..4].copy_from_slice(&0x1f3d5b79u32.to_le_bytes());
        h[4..8].copy_from_slice(&32u32.to_le_bytes()); h[10..12].copy_from_slice(&2u16.to_le_bytes());
        h[12..16].copy_from_slice(&64u32.to_le_bytes()); h[16..20].copy_from_slice(&5u32.to_le_bytes());
        server.write_all(&h).await.unwrap(); server.shutdown().await.unwrap();
        assert!(Dtx::new(client).receive().await.is_err());
    }
    #[tokio::test]
    async fn snapshot_response_with_wrong_attribute_is_rejected() {
        use crate::ax_archive::{AxValue, Token};
        let t = AxValue::Map(vec![
            (AxValue::String("pid".into()), AxValue::Integer(7.into())),
            (AxValue::String("objectID".into()), AxValue::Integer(9.into())),
            (AxValue::String("isApplicationElement".into()), AxValue::Bool(true)),
        ]);
        let token = Token::from_value(&t).unwrap();
        let (client, server) = tokio::io::duplex(64 * 1024);
        let mut remote = Dtx::new(server);
        let task = tokio::spawn(async move { Dtx::new(client).semantic(2, vec![1], Some(&token), None).await });
        let call = remote.receive().await.unwrap(); remote.reply(call.header, None).await.unwrap();
        let associated = dict([("pid", Value::Integer(7.into())), ("objectID", Value::Integer(9.into()))]);
        let reply = dict([("associatedRequestType", Value::Integer(2.into())), ("attribute", Value::Integer(51.into())),
                          ("associatedTranslationObject", associated), ("resultData", Value::String("fixture".into()))]);
        send_dispatch(&mut remote, 22, "processDataFromRemoteDevice:", &[Value::Data(archive(&reply).unwrap())], true).await;
        assert_eq!(remote.receive().await.unwrap().kind, 0);
        assert_eq!(task.await.unwrap(), Err(Failure::Mismatch));
    }
    #[tokio::test]
    async fn timed_out_semantic_session_closes_its_stream() {
        let (client, server) = tokio::io::duplex(4096);
        let mut remote = Dtx::new(server);
        let task = tokio::spawn(async move {
            let mut session = Dtx::new(client);
            tokio::time::timeout(Duration::from_millis(25), session.semantic(1, vec![1], None, None)).await
        });
        let call = remote.receive().await.unwrap(); remote.reply(call.header, None).await.unwrap();
        assert!(task.await.unwrap().is_err());
        assert!(remote.receive().await.is_err());
    }
}

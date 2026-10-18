// SPDX-License-Identifier: GPL-3.0-only
//! Configurable VPN packet-reflection path. No relay preamble or default-route fallback.
use crate::{DialFuture, CoreDeviceConnector, Purpose, Stream};
use std::{
    io,
    net::Ipv4Addr,
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};
use tokio::net::TcpSocket;

pub struct LocalVPNConnector {
    interface_index: u32,
    pairing_port: u16,
    local: Ipv4Addr,
    peer: Ipv4Addr,
    opened: AtomicBool,
    tunnel_opened: AtomicBool,
}
impl LocalVPNConnector {
    #[cfg(test)]
    pub fn new(interface_index: u32, pairing_port: u16) -> io::Result<Self> {
        Self::configured(interface_index, pairing_port, Ipv4Addr::new(10, 7, 1, 1), Ipv4Addr::new(10, 7, 0, 1))
    }
    pub fn configured(interface_index: u32, pairing_port: u16, local: Ipv4Addr, peer: Ipv4Addr) -> io::Result<Self> {
        let valid = |ip: Ipv4Addr| ip.octets()[0] != 0 && ip.octets()[0] != 127 && ip.octets()[0] < 224;
        if interface_index == 0 || pairing_port == 0 || !valid(local) || !valid(peer) || local == peer {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        Ok(Self {
            interface_index,
            pairing_port,
            local,
            peer,
            opened: AtomicBool::new(false),
            tunnel_opened: AtomicBool::new(false),
        })
    }
    fn consume_port(&self, purpose: Purpose) -> io::Result<u16> {
        match purpose {
            Purpose::PairVerify if !self.opened.swap(true, Ordering::SeqCst) => {
                Ok(self.pairing_port)
            }
            Purpose::NegotiatedTunnel { port }
                if port != 0
                    && self.opened.load(Ordering::SeqCst)
                    && !self.tunnel_opened.swap(true, Ordering::SeqCst) =>
            {
                Ok(port)
            }
            _ => Err(io::ErrorKind::InvalidInput.into()),
        }
    }
    async fn open(&self, purpose: Purpose) -> io::Result<Stream> {
        let port = self.consume_port(purpose)?;
        let socket = TcpSocket::new_v4()?;
        bind_interface(&socket, self.interface_index, self.local)?;
        let local = self.local;
        socket.bind((local, 0).into())?;
        let stream = tokio::time::timeout(
            Duration::from_secs(4),
            socket.connect((self.peer, port).into()),
        )
        .await
        .map_err(|_| io::Error::from(io::ErrorKind::TimedOut))??;
        if stream.local_addr()?.ip() != local {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        stream.set_nodelay(true)?;
        Ok(Box::new(stream))
    }
}
impl CoreDeviceConnector for LocalVPNConnector {
    fn connect(&self, purpose: Purpose) -> DialFuture<'_> {
        Box::pin(self.open(purpose))
    }
}
#[cfg(target_vendor = "apple")]
fn bind_interface(socket: &TcpSocket, index: u32, local: Ipv4Addr) -> io::Result<()> {
    use std::{ffi::CStr, os::fd::AsRawFd};
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    if unsafe { libc::getifaddrs(&mut head) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let mut current = head;
    let mut matches = 0;
    while !current.is_null() {
        let row = unsafe { &*current };
        if !row.ifa_addr.is_null()
            && !row.ifa_name.is_null()
            && unsafe { (*row.ifa_addr).sa_family } == libc::AF_INET as u8
            && unsafe { libc::if_nametoindex(row.ifa_name) } == index
            && unsafe { CStr::from_ptr(row.ifa_name) }
                .to_bytes()
                .starts_with(b"utun")
        {
            let addr = unsafe { &*(row.ifa_addr as *const libc::sockaddr_in) };
            let flags = row.ifa_flags as i32;
            if addr.sin_addr.s_addr.to_ne_bytes() == local.octets()
                && flags & (libc::IFF_UP | libc::IFF_RUNNING | libc::IFF_POINTOPOINT)
                    == (libc::IFF_UP | libc::IFF_RUNNING | libc::IFF_POINTOPOINT)
                && flags & libc::IFF_LOOPBACK == 0
            {
                matches += 1;
            }
        }
        current = row.ifa_next;
    }
    unsafe { libc::freeifaddrs(head) };
    if matches != 1 {
        return Err(io::ErrorKind::AddrNotAvailable.into());
    }
    let result = unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            libc::IPPROTO_IP,
            libc::IP_BOUND_IF,
            &index as *const _ as *const libc::c_void,
            std::mem::size_of_val(&index) as libc::socklen_t,
        )
    };
    if result != 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}
#[cfg(not(target_vendor = "apple"))]
fn bind_interface(_: &TcpSocket, _: u32, _: Ipv4Addr) -> io::Result<()> {
    Err(io::ErrorKind::Unsupported.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn exact_pairing_and_negotiated_ports_no_replay_or_lockdown() {
        assert!(LocalVPNConnector::new(0, 1234).is_err());
        assert!(LocalVPNConnector::new(1, 0).is_err());
        let c = LocalVPNConnector::new(1, 1234).unwrap();
        assert!(
            c.consume_port(Purpose::NegotiatedTunnel { port: 4321 })
                .is_err()
        );
        assert!(c.consume_port(Purpose::LockdownSession).is_err());
        assert_eq!(c.consume_port(Purpose::PairVerify).unwrap(), 1234);
        assert!(c.consume_port(Purpose::PairVerify).is_err());
        assert!(
            c.consume_port(Purpose::NegotiatedTunnel { port: 0 })
                .is_err()
        );
        assert_eq!(
            c.consume_port(Purpose::NegotiatedTunnel { port: 4321 })
                .unwrap(),
            4321
        );
        assert!(
            c.consume_port(Purpose::NegotiatedTunnel { port: 4321 })
                .is_err()
        );
    }
    #[test]
    fn custom_addresses_preserve_octets_and_reject_invalid_peers() {
        let local = Ipv4Addr::from(0x0a080101u32);
        let peer = Ipv4Addr::from(0x0a080001u32);
        let c = LocalVPNConnector::configured(77, 4321, local, peer).unwrap();
        assert_eq!(c.local.octets(), [10, 8, 1, 1]);
        assert_eq!(c.peer.octets(), [10, 8, 0, 1]);
        for bad in [Ipv4Addr::UNSPECIFIED, Ipv4Addr::LOCALHOST, Ipv4Addr::new(224, 0, 0, 1), Ipv4Addr::BROADCAST, local] {
            assert!(LocalVPNConnector::configured(77, 4321, local, bad).is_err());
        }
    }
    #[tokio::test]
    async fn missing_interface_fails_without_default_routing_or_retry() {
        let c = LocalVPNConnector::new(u32::MAX, 1234).unwrap();
        assert!(c.connect(Purpose::PairVerify).await.is_err());
        assert!(c.connect(Purpose::PairVerify).await.is_err());
    }
}

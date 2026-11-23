//! Pairs this computer with an Apple Vision Pro (or Apple TV) the way Xcode does, and writes the RPPairing
//! file Henge's built-in JIT imports (Settings › JIT › Use a pairing file).
//!
//! visionOS pairs the opposite way round from iOS 27's on-device pairing: while Settings › General › Remote
//! Devices is open, the headset advertises `_remotepairing-manual-pairing._tcp`, a host connects to it, the
//! headset shows a code and the host sends it back.
//!
//!   henge-vision-pair HOST PORT OUT.plist     (pair.sh finds HOST and PORT with dns-sd)
//! The code is read from standard input.

use idevice::remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::TcpStream;

const HOST_NAME: &str = "Henge";

#[tokio::main(flavor = "current_thread")]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        eprintln!("usage: {} HOST PORT OUT.plist", args[0]);
        std::process::exit(2);
    }
    let (host, port, out) = (&args[1], &args[2], &args[3]);
    let port: u16 = port.parse().expect("PORT is a number");

    let stream = TcpStream::connect((host.as_str(), port)).await.unwrap_or_else(|e| {
        eprintln!("could not connect to {host}:{port}: {e}");
        std::process::exit(1)
    });
    eprintln!("connected to {host}:{port}");

    let mut file = RpPairingFile::generate(HOST_NAME);
    let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), HOST_NAME);
    let result = client
        .connect(&mut file, || async {
            eprintln!("enter the code the headset shows:");
            let mut line = String::new();
            let _ = BufReader::new(tokio::io::stdin()).read_line(&mut line).await;
            line.trim().to_string()
        })
        .await;
    if let Err(e) = result {
        eprintln!("pairing failed: {e:?}");
        std::process::exit(1);
    }
    std::fs::write(out, file.to_bytes()).expect("write the pairing file");
    match client.paired_peer_device() {
        Ok(peer) => eprintln!("paired with {peer:?}"),
        Err(_) => eprintln!("paired"),
    }
    eprintln!("wrote {out}");
}

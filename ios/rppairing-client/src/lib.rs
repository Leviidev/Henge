// SPDX-License-Identifier: GPL-2.0-or-later
//! Pairs with a device as the computer, the way Xcode pairs with an Apple Vision Pro: Henge connects to the
//! device's `_remotepairing-manual-pairing._tcp` service (through the loopback VPN, at 10.7.0.1, when the device
//! is the one Henge runs on), the device shows a code, and Henge sends back the code the user types. The result
//! is the RPPairing file Built-in StikJIT uses. Henge's other pairing (Husk's husk_rppairing) runs the other way
//! round, for iOS 27, which visionOS doesn't offer.

use std::ffi::{CStr, CString, c_char, c_void};
use std::time::Duration;

use idevice::remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket};
use tokio::net::TcpStream;

/// Asks Henge for the code the device shows. Called on the pairing thread, and may block until the user has typed
/// it. Returns a string allocated with malloc (strdup), which is freed here, or NULL to cancel.
pub type HengeRPClientCodeProvider = Option<extern "C" fn(context: *mut c_void) -> *mut c_char>;

unsafe extern "C" {
    fn free(pointer: *mut c_void);
}

/// How long the whole pairing may take, the user typing the code included.
const TIMEOUT: Duration = Duration::from_secs(300);

fn set_error(out: *mut *mut c_char, message: impl Into<Vec<u8>>) {
    if out.is_null() {
        return;
    }
    let message = CString::new(message).unwrap_or_else(|_| CString::new("pairing failed").unwrap());
    unsafe { *out = message.into_raw() };
}

struct Provider {
    callback: extern "C" fn(*mut c_void) -> *mut c_char,
    context: *mut c_void,
}

// The provider is only called on the thread that called henge_rpclient_pair.
unsafe impl Send for Provider {}
unsafe impl Sync for Provider {}

impl Provider {
    fn code(&self) -> Option<String> {
        let raw = (self.callback)(self.context);
        if raw.is_null() {
            return None;
        }
        let code = unsafe { CStr::from_ptr(raw) }.to_string_lossy().trim().to_string();
        unsafe { free(raw.cast()) };
        Some(code)
    }
}

/// Pairs with the device listening at `host`:`port`, calling `provider` for the code, and returns the pairing file
/// (an XML plist) in `out_bytes`/`out_len`; free it with henge_rpclient_bytes_free. Blocks until it is done.
/// Returns 0 when paired, 1 when cancelled (the provider returned NULL), -1 on failure with `error` set (free with
/// henge_rpclient_string_free).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn henge_rpclient_pair(
    host: *const c_char,
    port: u16,
    host_name: *const c_char,
    provider: HengeRPClientCodeProvider,
    context: *mut c_void,
    out_bytes: *mut *mut u8,
    out_len: *mut usize,
    error: *mut *mut c_char,
) -> i32 {
    let (Some(callback), false, false) = (provider, host.is_null(), host_name.is_null()) else {
        set_error(error, "missing argument");
        return -1;
    };
    let host = unsafe { CStr::from_ptr(host) }.to_string_lossy().into_owned();
    let name = unsafe { CStr::from_ptr(host_name) }.to_string_lossy().into_owned();
    let provider = Provider { callback, context };

    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(e) => {
            set_error(error, format!("could not start: {e}"));
            return -1;
        }
    };
    let result = runtime.block_on(async {
        tokio::time::timeout(TIMEOUT, pair(&host, port, &name, &provider))
            .await
            .unwrap_or(Err(Failure::Error("pairing took too long".into())))
    });
    match result {
        Ok(bytes) => {
            let boxed = bytes.into_boxed_slice();
            unsafe {
                *out_len = boxed.len();
                *out_bytes = Box::into_raw(boxed).cast();
            }
            0
        }
        Err(Failure::Cancelled) => 1,
        Err(Failure::Error(message)) => {
            set_error(error, message);
            -1
        }
    }
}

enum Failure {
    Cancelled,
    Error(String),
}

async fn pair(host: &str, port: u16, name: &str, provider: &Provider) -> Result<Vec<u8>, Failure> {
    let stream = TcpStream::connect((host, port))
        .await
        .map_err(|e| Failure::Error(format!("could not connect to the pairing service: {e}")))?;
    let mut file = RpPairingFile::generate(name);
    let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), name);
    let cancelled = std::sync::atomic::AtomicBool::new(false);
    let result = client
        .connect(&mut file, || {
            let code = provider.code();
            if code.is_none() {
                cancelled.store(true, std::sync::atomic::Ordering::SeqCst);
            }
            async move { code.unwrap_or_default() }
        })
        .await;
    if cancelled.load(std::sync::atomic::Ordering::SeqCst) {
        return Err(Failure::Cancelled);
    }
    result.map_err(|e| Failure::Error(format!("{e}")))?;
    Ok(file.to_bytes())
}

/// Frees the pairing file henge_rpclient_pair returned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn henge_rpclient_bytes_free(bytes: *mut u8, len: usize) {
    if !bytes.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes, len)) });
    }
}

/// Frees an error string henge_rpclient_pair returned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn henge_rpclient_string_free(string: *mut c_char) {
    if !string.is_null() {
        drop(unsafe { CString::from_raw(string) });
    }
}
